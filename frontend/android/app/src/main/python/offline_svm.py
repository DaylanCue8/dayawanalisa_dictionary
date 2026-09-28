"""
NumPy-only replacement for a trained sklearn SVC (kernel='rbf',
probability=True). Loads the parameters exported by
export_models_for_android.py (a .npz file) and gives the same
predict() and predict_proba() results, so the pen/marker services can
use it exactly like the joblib model:

    model = OfflineSVC('model_base.npz')
    model.predict(features)          # class index, like SVC.predict
    model.predict_proba(features)    # like SVC.predict_proba

Follows libsvm: one-vs-one decision values, voting for predict, and
Platt scaling + pairwise coupling (Wu, Lin & Weng) for probabilities.
"""
import numpy as np


class OfflineSVC:
    def __init__(self, npz_path):
        data = np.load(npz_path, allow_pickle=False)
        self.support_vectors = data['support_vectors'].astype(np.float64)
        self.dual_coef = data['dual_coef'].astype(np.float64)       # (k-1, n_sv)
        self.intercept = data['intercept'].astype(np.float64)       # (k*(k-1)/2,)
        self.n_support = data['n_support'].astype(np.int64)         # (k,)
        self.prob_a = data['prob_a'].astype(np.float64)
        self.prob_b = data['prob_b'].astype(np.float64)
        self.gamma = float(data['gamma'])
        self.classes_ = data['classes']
        self.n_classes = len(self.n_support)
        self._starts = np.concatenate([[0], np.cumsum(self.n_support)[:-1]])
        self._sv_sq = np.sum(self.support_vectors ** 2, axis=1)
        self._cache_key = None
        self._cache_value = None

    # ---- kernel + one-vs-one decision values ----
    def _kernel(self, X):
        X = np.atleast_2d(np.asarray(X, dtype=np.float64))
        sq_dist = (np.sum(X ** 2, axis=1)[:, None] + self._sv_sq[None, :]
                   - 2.0 * X @ self.support_vectors.T)
        np.maximum(sq_dist, 0, out=sq_dist)
        return np.exp(-self.gamma * sq_dist)

    def decision_ovo(self, X):
        """(n_samples, k*(k-1)/2) decision values in libsvm's pair order."""
        X = np.atleast_2d(np.asarray(X, dtype=np.float64))
        key = (X.shape, X.tobytes())
        if key == self._cache_key:   # predict + predict_proba on the same glyph
            return self._cache_value
        K = self._kernel(X)
        k = self.n_classes
        out = np.zeros((X.shape[0], k * (k - 1) // 2))
        p = 0
        for i in range(k):
            si, ni = self._starts[i], self.n_support[i]
            for j in range(i + 1, k):
                sj, nj = self._starts[j], self.n_support[j]
                value = (K[:, si:si + ni] @ self.dual_coef[j - 1, si:si + ni]
                         + K[:, sj:sj + nj] @ self.dual_coef[i, sj:sj + nj])
                out[:, p] = value + self.intercept[p]
                p += 1
        self._cache_key, self._cache_value = key, out
        return out

    # ---- predict: one-vs-one voting (ties -> lowest class index) ----
    def predict(self, X):
        dec = self.decision_ovo(X)
        k = self.n_classes
        predictions = []
        for row in dec:
            votes = np.zeros(k, dtype=np.int64)
            p = 0
            for i in range(k):
                for j in range(i + 1, k):
                    if row[p] > 0:
                        votes[i] += 1
                    else:
                        votes[j] += 1
                    p += 1
            predictions.append(self.classes_[int(np.argmax(votes))])
        return np.array(predictions)

    # ---- predict_proba: Platt scaling + pairwise coupling ----
    @staticmethod
    def _sigmoid(f, a, b):
        fapb = f * a + b
        if fapb >= 0:
            return np.exp(-fapb) / (1.0 + np.exp(-fapb))
        return 1.0 / (1.0 + np.exp(fapb))

    @staticmethod
    def _multiclass_probability(k, r):
        p = np.full(k, 1.0 / k)
        Q = np.zeros((k, k))
        for t in range(k):
            for j in range(t):
                Q[t, t] += r[j, t] * r[j, t]
                Q[t, j] = Q[j, t]
            for j in range(t + 1, k):
                Q[t, t] += r[j, t] * r[j, t]
                Q[t, j] = -r[j, t] * r[t, j]
        eps = 0.005 / k
        max_iter = max(100, k)
        Qp = np.zeros(k)
        for _ in range(max_iter):
            pQp = 0.0
            for t in range(k):
                Qp[t] = float(Q[t] @ p)
                pQp += p[t] * Qp[t]
            if np.max(np.abs(Qp - pQp)) < eps:
                break
            for t in range(k):
                diff = (-Qp[t] + pQp) / Q[t, t]
                p[t] += diff
                pQp = (pQp + diff * (diff * Q[t, t] + 2 * Qp[t])) / (1 + diff) / (1 + diff)
                Qp = (Qp + diff * Q[t]) / (1 + diff)
                p = p / (1 + diff)
        return p

    def predict_proba(self, X):
        dec = self.decision_ovo(X)
        k = self.n_classes
        min_prob = 1e-7
        result = np.zeros((dec.shape[0], k))
        for n, row in enumerate(dec):
            r = np.zeros((k, k))
            p = 0
            for i in range(k):
                for j in range(i + 1, k):
                    value = self._sigmoid(row[p], self.prob_a[p], self.prob_b[p])
                    value = min(max(value, min_prob), 1 - min_prob)
                    r[i, j] = value
                    r[j, i] = 1 - value
                    p += 1
            if k == 2:
                result[n] = [r[0, 1], r[1, 0]]
            else:
                result[n] = self._multiclass_probability(k, r)
        return result
