#!python
#cython: language_level=3, annotation_typing=True
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import label_binarize
from sklearn.utils.validation import check_is_fitted
from sklearn.feature_extraction.dict_vectorizer import DictVectorizer
from sklearn.exceptions import NotFittedError
from sklearn.metrics import brier_score_loss

from copy import deepcopy
from itertools import groupby
from symlearn.utils import VocabularyDict
from operator import itemgetter

from stanfordSentimentTreebank import preprocess_data

import typing
import logging
import pandas
import numpy
import scipy
import joblib
import gc
import os

cimport cython


#TODO: write prune code
def cost_complexity_pruning(X, y, alpha, tree_clf):
    """
    doing cost_complexity pruning
    """
    assert(hasattr(tree_clf, 'tree_'))
    prune_tree = deepcopy(tree_clf.tree_)

    # compute current cost complexity criterion
    terminals = numpy.arange(len(tree_clf.tree_.feature))[tree_clf.tree_.feature < 0]
    complex_cost = numpy.zeros_like(terminals, dtype=numpy.float) 
    # sklearn.tree._tree.Tree.apply only takes float32
    regions = tree_clf._tree.apply(X.view(numpy.float32))  
    uniq_reg, uniq_count = numpy.unique(regions, return_counts=True)
    y_pred = tree_clf.predict(X)
    for i in range(len(terminals)):
        sel = (regions == terminals[i])
        complex_cost[i] =  numpy.nan_to_num(numpy.sum(y[sel] != y_pred[sel]))
    ttl_cost = complex_cost.sum() + alpha * len(terminals) 
    
    # conduct weakest link pruning
    internals = set(numpy.arange(1, len(tree_clf._tree.feature))) - set(terminals)

     
#TODO: part of pruning code
def depth_first_traversal(tree_clf):
    """
    to extract the split rule
    """
    # traverse decision tree via depth-first traversal, starting from root
    stack_ = [(-1, 0)] # index of root node is zero
    paths_ = {}
    # 0 for not visited, 1 for visiting left children, 2 for visiting right children
    indicator = numpy.zeros_like(tree_clf.tree_.feature) 
    count = 0
    direction = ['L', 'R']
    while len(stack_) != 0 and count < 2 * len(tree_clf.tree_.feature):
        cur_node = stack_[-1][-1]
        is_terminal = False
        if indicator[cur_node] == 0:
            if tree_clf.tree_.children_left[cur_node] != -1:
                stack_.append((0, tree_clf.tree_.children_left[cur_node]))
                indicator[cur_node] += 1
            else: # terminal corresponding a rule
                is_terminal = True
        elif indicator[cur_node] == 1:
            if tree_clf.tree_.children_right[cur_node] != -1:
                stack_.append((1, tree_clf.tree_.children_right[cur_node]))
                indicator[cur_node] += 1
            else:
                is_terminal = True
        else:
            stack_.pop()
        if is_terminal:
            paths_[cur_node] = [n for n in stack_]
            print(cur_node, ":" , ' -> '.join(map(str, paths_[cur_node])))
            stack_.pop()
        count += 1
        assert(numpy.all(indicator <= 2))
    assert(tree_clf.tree_.node_count - numpy.sum(tree_clf.tree_.children_right >
        0) == len(paths_))
    return(paths_)


#@cython.ccall
def process_joint_features(data:typing.Tuple, vectorizer:DictVectorizer=None, 
    n_levels:int=-1, n_classes:int=5) -> typing.Iterable:
    """
    process sentiment value and level value from phrase as a join feature

    Parameters
    ----------  
    @param data: tuple
        consisting ids, sentiments and levels of the full training data set
    @param vectorizer: scikit-learn transformer instance
        will vectorize and quantify raw features
    @param n_levels: int
        the maximal levels existing in the data
    @param n_classes: int
        the number of 
    """
    predicted_labels, features = data
    sizes = numpy.hstack([0, features['levels'].apply(len).cumsum().values])
    if predicted_labels[0].ndim == 1:
        predicted_labels = label_binarize(numpy.hstack(predicted_labels),
            numpy.arange(n_classes), sparse_output=False)
    else:
        predicted_labels  = numpy.vstack(predicted_labels)
    
    # the max level existing in the current data
    if n_levels < 0:
        n_levels = numpy.unique(numpy.hstack(features['levels'])).max()
    
    samples = [scipy.sparse.dok_matrix((n_levels + 1, n_classes), dtype=numpy.float32) 
            for _ in range(len(features))]

    masked_levels = numpy.ma.masked_equal(numpy.hstack(features['levels'].values), 0, copy=False)
    masked_labels = numpy.ma.masked_array(predicted_labels, 
                                          mask=numpy.tile(masked_levels.mask[:, numpy.newaxis], 
                                          (1, n_classes)), copy=False)
    numpy.testing.assert_array_almost_equal(masked_labels.sum(axis=1), 
                numpy.ones(len(masked_labels)))
   
    for i, (cur_start, cur_end) in enumerate(zip(sizes[:-1], sizes[1:])):
        for l in range(1, n_levels + 1):
            if any(masked_levels[cur_start:cur_end] == l):
                samples[i][l] = masked_labels[cur_start: cur_end][
                    masked_levels[cur_start:cur_end] == l].sum(axis=0).compressed()
            elif all(masked_levels[cur_start:cur_end] <= l):
                break

    if not vectorizer:  # no valid vectorizer is availabel
        return samples

    try:
        check_is_fitted(vectorizer, "vocabulary_")
    except AttributeError:  # not really able to catch NotFittedError
        raw_features = vectorizer.fit_transform(samples)
    else:
        raw_features = vectorizer.transform(samples)
    return(raw_features)


def enumerate_subspaces(masked_levels, masked_labels):
    """
    generator to enumerate the restricted subspaces of features which include
    [3, 5] lables x [2, 4, 8, 16, 32] levels 

    >>> gen = enumerate_subspaces(numpy.arange(32).view(numpy.ma.MaskedArray),
    ... numpy.arange(5).view(numpy.ma.MaskedArray))
    >>> level, label = next(gen)
    >>> numpy.testing.assert_array_equal(level.compressed(), numpy.arange(32))
    >>> numpy.testing.assert_array_equal(label.compressed(), numpy.arange(5))
    >>> level, label = next(gen)
    >>> numpy.testing.assert_array_equal(level.compressed(), 
    ... numpy.hstack([numpy.arange(16), 16 * numpy.ones((16,), dtype=numpy.int)]))
    >>> level, label = next(gen)
    >>> numpy.testing.assert_array_equal(level.compressed(), 
    ... numpy.hstack([numpy.arange(8), 8 * numpy.ones((24,), dtype=numpy.int)]))
    >>> level, label = next(gen)
    >>> numpy.testing.assert_array_equal(level.compressed(), 
    ... numpy.hstack([numpy.arange(4), 4 * numpy.ones((28,), dtype=numpy.int)]))
    >>> level, label = next(gen)
    >>> numpy.testing.assert_array_equal(level.compressed(), 
    ... numpy.hstack([numpy.arange(2), 2 * numpy.ones((30,), dtype=numpy.int)]))
    >>> numpy.testing.assert_array_equal(label.compressed(), numpy.arange(5))
    >>> level, label = next(gen)
    >>> numpy.testing.assert_array_equal(level.compressed(), numpy.arange(32))
    >>> numpy.testing.assert_array_equal(label.compressed(), [0, 0, 1, 2, 2])
    """

    labels_cutoff = [3, 5]
    levels_cutoff = numpy.logspace(1, 5, 5, base=2, dtype=numpy.int) 
    uniq_labels = numpy.unique(masked_labels)
    uniq_levels = numpy.unique(masked_levels)
    for n_labels in reversed(labels_cutoff):
        sub_labels = masked_labels.copy() 
        if len(uniq_labels) != n_labels:
            # only for n_labels = 3
            sub_labels[sub_labels < len(uniq_labels) // 2] = n_labels // 2 - 1 
            sub_labels[sub_labels == len(uniq_labels) // 2] = n_labels // 2 
            sub_labels[sub_labels > len(uniq_labels) // 2] = n_labels // 2 + 1 
            sub_labels.mask = masked_labels.mask 
        else:
            sub_labels = masked_labels
        for n_levels in reversed(levels_cutoff):
            sub_levels = masked_levels.copy() 
            if len(uniq_levels) != n_levels:
                sub_levels[sub_levels > n_levels] = n_levels 
            sub_levels.mask = masked_levels.mask 
            yield sub_levels, sub_labels


#@cython.ccall
def transform_features(csv_file:str, n_rows:int=-1, preproc:Pipeline=None, 
    vocab:VocabularyDict=None) -> pandas.DataFrame:
    """
    transform phrases from string to integer-encoding list based on 
    the vocabulary set

    Parameters
    ----------
    @param: csv_file, string
        the path used to store tree relevant data
    @param: n_rows, integer
        the number of line to read in from csv_file specified above
    @param: preproc, (on constructing)
    @param: vocab, (on constructing)
    """
    cdef:
        int i, uid

    ids, sentences, sentiments, levels, weights, phrases_pos = \
            preprocess_data(csv_file, n_rows=n_rows)

    uniq_ids = numpy.unique(ids)
    features = {'ids': numpy.empty((len(uniq_ids),), dtype=numpy.object), 
                'wordtokens': numpy.empty((len(uniq_ids),), dtype=numpy.object),
                'sentiments': numpy.empty((len(uniq_ids),), dtype=numpy.object),
                'levels': numpy.empty((len(uniq_ids),), dtype=numpy.object),
                'phrases': numpy.empty((len(uniq_ids),), dtype=numpy.object)}
    # masking the sentiments for partial phrases 
    sentiments = sentiments.view(numpy.ma.MaskedArray)
    sentiments[levels==0] = numpy.ma.masked 
    for i, uid in enumerate(uniq_ids):
        features['ids'][i] = ids[ids == uid]
        features['sentiments'][i] = sentiments[ids == uid]
        features['levels'][i] = levels[ids == uid]

    if vocab:
        # transform sentences and phrases 
        wordtokens = list(map(lambda words: [vocab[w] for w in words],
                sentences.tolist()))   # augment with phrases 
        phrases = numpy.asarray([wordtokens[i][start_pos:end_pos] for i, tree_id in
                enumerate(ids[levels==0])
                for start_pos, end_pos in phrases_pos[tree_id]])

        assert(len(phrases)==len(ids))  # check both lengths are the same
        assert(all(list(map(lambda x: len(x) > 0, phrases))))
        del sentences
        gc.collect()

        for i, uid in enumerate(uniq_ids):
            features['wordtokens'][i] = wordtokens[i]
            features['phrases'][i] = phrases[ids == uid]
    return features


#@cython.ccall
def group_fit(features:pandas.DataFrame, preproc:Pipeline, 
    estimators:list, max_level:int) -> list:
  """
  fitting a list of naive bayes estimators
  """

  # transform by preproc
  proced = phrases.tolist()
  for name, trans in preproc.steps:
    try:
        proced = trans.transform(proced)
    except NotFittedError as e:
        proced = trans.fit_transform(proced, levels)


  Xt = [[] for _ in numpy.arange(max_level)]
  Yt = [[] for _ in numpy.arange(max_level)]

  for key, grp in groupby(sorted([(p, t, l) for p, t, l in 
                                  zip(proced, sentiments.data.tolist(),
                                      levels.tolist())], 
                                 key=itemgetter(-1)), key=itemgetter(-1)):

    if key > 0:  # don't count in root levels
      if key >= max_level:
        est_idx = -1
      else:
        est_idx = key - 1
      phrase, targets, _  = zip(*grp)
      Xt[est_idx].append(phrase)
      Yt[est_idx].append(targets)

  for xt, yt, est in zip(Xt, Yt, estimators):
    xt = numpy.vstack(xt)
    yt = numpy.hstack(yt)
    est.fit(xt, yt)

    # report and save brier_score to the CalibrationCV instance
    assert(yt.ndim == 2)
    if not hasattr(est, 'cv_results_'):
        cv_results_ = {}
        # compute micro means
        cv_results_['split_brier_score'] = map(
            lambda clf, x, y: brier_score_loss(yt.ravel(), clf.predict_proba(xt).ravel()), 
            est.calibrated_classifiers_)
        setattr(est, 'cv_results_', cv_results_)
        cv_results_['mean_test_score'] = numpy.mean(cv_results_['split_brier_score'])
        cv_results_['std_test_score'] = numpy.std(cv_results_['split_brier_score'])
  return estimators


@cython.cclass
class labels_to_attributes(object):

    cython.declare(n_classes=cython.int, using_probs=cython.bint)

    def __init__(self, preproc:Pipeline, vectorizer:DictVectorizer, 
                using_probs:bool=True, n_classes:int=5):
        self.preproc = preproc
        self.vectorizer = vectorizer
        self.n_classes = n_classes
        self.using_probs = using_probs


    #@cython.ccall
    def __call__(self, raw_data:pandas.DataFrame, y:list=None, 
        label_predictors:list=None) -> typing.Iterable:
      """
      Parameters
      ----------
      @param raw_data: tuple
        store the (ids, levels, phrases) data properties in order
        to slice data
        ids: numpy array used to store actual sentence id
        merged_levels: numpy array used to store index to retrieve corresponding lable_predictors
        phrases: list or numpy array used to store not processed words and phrases
      @param y: list or numpy.array
        store the targets (should be passed along by sklearn.FunctionTransformer)
      @param label_predictors: list of sklearn.BaseEstimators
        a list of sklearn.BaseEstimators instances which should have predict or predict_proba methods
      """
      cdef:
        int i, level, start=0, end=0

      levels = numpy.hstack(raw_data['levels'])
      phrases = numpy.hstack(raw_data['phrases'])

      n_samples = len(levels)
      Xt = self.preproc.transform(phrases)  # phrases to matrix

      uniq_levels = numpy.arange(1, numpy.unique(levels).max() + 1)  # not reduced levels
      
      logging.debug('using prediction probabilities as label attributes %s'
      ' with %d levels (maximal level = %d)'%(
        str(self.using_probs), uniq_levels[-1], len(label_predictors)))

      if self.using_probs:
        sentiment_probs = numpy.empty((n_samples, self.n_classes),
            dtype=numpy.float32)
        func_name = 'predict_proba'
      else:  # using rank 1
        sentiment_probs = numpy.empty((n_samples,), dtype=numpy.float32)
        func_name = 'predict'

      try:
        check_is_fitted(label_predictors[0], 'theta_')
      except AttributeError:
        group_fit(raw_data, self.preproc, label_predictors, 
            len(label_predictors))

      for level in uniq_levels:
        if level >= len(label_predictors):
            est_id = -1
        else:
            est_id = level - 1
        sentiment_probs[levels == level] = \
            getattr(label_predictors[est_id], func_name)(Xt[levels == level])

      stack_sentprobs = numpy.empty((len(raw_data),), dtype=numpy.object)
      start, end = 0, 0
      for i, cur_sent in enumerate(raw_data['sentiments']):
        end += len(cur_sent)
        numpy.testing.assert_array_almost_equal(sentiment_probs[start + 1: end].sum(axis=1), 
            numpy.ones(end - start - 1))
        stack_sentprobs[i] = sentiment_probs[start:end]
        start = end
      features = process_joint_features((stack_sentprobs, raw_data), 
        n_levels=uniq_levels[-1], vectorizer=self.vectorizer)
      return features
