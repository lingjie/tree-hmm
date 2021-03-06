#!python
#cython: boundscheck=False, wraparound=False
# can also add profile=True

cimport cython
from cython.parallel import prange
import numpy as np
import sys
import copy
cimport numpy as np
from libc.math cimport exp, log

#from ipdb import set_trace as breakpoint




@cython.profile(False)
cpdef inline np.float64_t log_obs(Py_ssize_t i, Py_ssize_t t, Py_ssize_t k, np.float64_t[:,:] emit_probs, np.int8_t[:,:,:] X) nogil:
    """Get the emission probability for the given X[i,t,k]"""
    cdef np.float64_t total = 0.
    cdef Py_ssize_t l
    for l in xrange(X.shape[2]):
        if X[i,t,l]:
            total += log(emit_probs[k,l])
        else:
            total += log(1. - emit_probs[k,l])
    return total


cpdef make_log_obs_matrix(args):
    """Update p(X^i_t|Z^i_t=k, emit_probs) (I,T,K) from current emit_probs"""
    cdef np.ndarray[np.float64_t, ndim=3] log_obs_mat = args.log_obs_mat
    cdef np.int8_t[:,:,:] X = args.X
    cdef np.float64_t[:,:] emit = args.emit_probs
    cdef Py_ssize_t I = X.shape[0], T = X.shape[1], K = emit.shape[0]
    cdef Py_ssize_t i,t,k
    #log_obs_mat[...] = np.zeros((I,T,K))
    log_obs_mat[:] = 0.
    #cdef np.float64_t[:,:,:] obs_mat_view = log_obs_mat
    #print 'making log_obs matrix'
    #for i in prange(I, nogil=True):
    for i in xrange(I):
        for t in xrange(T):
            for k in xrange(K):
                #obs_mat_view[i,t,k] = log_obs(i,t,k,emit,X)
                log_obs_mat[i,t,k] = log_obs(i,t,k,emit,X)


cpdef normalize_trans(np.ndarray[np.float64_t, ndim=3] theta,
                        np.ndarray[np.float64_t, ndim=2] alpha,
                        np.ndarray[np.float64_t, ndim=2] beta,
                        np.ndarray[np.float64_t, ndim=1] gamma):
    """renormalize transition matrices appropriately"""
    cdef Py_ssize_t K, k, v, h
    K = gamma.shape[0]
    cdef np.ndarray[np.float64_t, ndim=2] t_sum = theta.sum(axis=2)
    cdef np.ndarray[np.float64_t, ndim=1] a_sum = alpha.sum(axis=1)
    cdef np.ndarray[np.float64_t, ndim=1] b_sum = beta.sum(axis=1)
    cdef np.float64_t g_sum = gamma.sum()
    # all probability goes to one of K states
    for k in range(K):
        for v in xrange(K):
            for h in xrange(K):
                theta[v, h, k] /= t_sum[v, h]
            alpha[v, k] /= a_sum[v]
            beta[v, k] /= b_sum[v]
    gamma /= g_sum


cpdef normalize_emit(np.ndarray[np.float64_t, ndim=3] Q,
                        np.ndarray[np.float64_t, ndim=2] emit_probs,
                        np.float64_t pseudocount, args, renormalize=True):
    """renormalize emission probabilities using Q"""
    cdef Py_ssize_t I, T, K, L, i, t, k, l
    I = Q.shape[0]
    T = Q.shape[1]
    K = emit_probs.shape[0]
    L = emit_probs.shape[1]
    cdef np.ndarray[np.float64_t, ndim=1] e_sum = np.ones(K, dtype=np.float64) * pseudocount
    # all probability goes to one of K states
    for k in range(K):
        for i in xrange(I):
            for t in xrange(T):
                e_sum[k] += Q[i,t,k]
    if renormalize:
        emit_probs[:] = np.dot(np.diag(1./e_sum), emit_probs)
    args.emit_sum = e_sum


cpdef mf_random_q(I, T, K):
    """Create a random Q distribution for mean-field inference"""
    # each i,t has a distribution over K
    Q = np.random.rand(I, T, K).astype(np.float64)
    q_sum = Q.sum(axis=2)
    for i in xrange(I):
        for t in xrange(T):
            Q[i, t, :] /= q_sum[i, t]
    return Q


cpdef np.float64_t mf_free_energy(args):
    """Calculate the free energy for Q"""
    cdef np.int8_t[:,:,:] X
    cdef np.float64_t[:,:,:] Q, theta
    cdef np.float64_t[:,:] alpha, beta, emit
    cdef np.float64_t[:] gamma
    cdef np.int8_t[:] vert_parent
    cdef np.float64_t[:,:,:] log_obs_mat
    X, Q, theta, alpha, beta, gamma, emit, vert_parent, vert_children, log_obs_mat = (args.X, args.Q, args.theta,
                                                   args.alpha, args.beta,
                                                   args.gamma, args.emit_probs, args.vert_parent, args.vert_children, args.log_obs_mat)
    cdef Py_ssize_t I = Q.shape[0], T = Q.shape[1], K = Q.shape[2]
    cdef Py_ssize_t i,t,v,h,k, ch_i, vp, len_v_chs
    cdef np.float64_t[:] log_gamma
    cdef np.float64_t[:,:] log_alpha, log_beta
    cdef np.float64_t[:,:,:] log_theta
    #print 'mf_free_energy'
    log_theta = np.log(theta)
    log_alpha = np.log(alpha)
    log_beta = np.log(beta)
    log_gamma = np.log(gamma)
    
    cdef np.float64_t total_free = (Q * np.log(Q)).sum()
    
    for i in xrange(I):
    #for i in prange(I, nogil=True):
        vp = vert_parent[i]
        for t in xrange(T):
            for k in xrange(K):
                for v in xrange(K):
                    if t == 0 and i ==0:
                        # GAMMA
                        total_free -= Q[i,t,k] * (log_gamma[k] + log_obs_mat[i,t,k])
                    else:
                        if i > 0 and t > 0:
                            # THETA
                            for h in xrange(K):
                                total_free -= Q[vp,t,v] * Q[i,t-1,h] * Q[i,t,k] * (log_theta[v,h,k] + log_obs_mat[i,t,k])
                        elif i == 0:
                            # ALPHA
                            total_free -= Q[i,t-1,v] * Q[i,t,k] * (log_alpha[v,k] + log_obs_mat[i,t,k])
                        else:
                            # BETA
                            total_free -= Q[vp,t,v] * Q[i,t,k] * (log_beta[v,k] + log_obs_mat[i,t,k])
    return total_free
    

cpdef mf_update_q(args):
    """Calculate q_{it} for the fixed parameters"""
    cdef np.int8_t[:,:,:] X
    cdef np.ndarray[np.float64_t, ndim=3] Q
    cdef np.float64_t[:,:,:] theta
    cdef np.float64_t[:,:] alpha, beta, emit
    cdef np.float64_t[:] gamma
    cdef np.int8_t[:] vert_parent
    cdef np.float64_t[:,:,:] log_obs_mat
    #Q = args.Q
    X = args.X
    Q, theta, alpha, beta, gamma, emit, vert_parent, vert_children, log_obs_mat = (args.Q, args.theta,
                                                   args.alpha, args.beta,
                                                   args.gamma, args.emit_probs, args.vert_parent, args.vert_children, args.log_obs_mat)
    args.Q_prev = copy.deepcopy(args.Q)
    cdef Py_ssize_t I = Q.shape[0], T = Q.shape[1], K = Q.shape[2]
    cdef Py_ssize_t i,t,v,h,k,ch_i,vp
    cdef Py_ssize_t len_v_chs
    cdef np.int32_t[:] v_chs
    cdef np.float64_t[:] log_gamma
    cdef np.float64_t[:,:] log_alpha, log_beta
    cdef np.float64_t[:,:,:] log_theta
    #print 'mf_update_q'
    log_theta = np.log(theta)
    log_alpha = np.log(alpha)
    log_beta = np.log(beta)
    log_gamma = np.log(gamma)

    #cdef np.ndarray[np.float64_t, ndim=2] phi = np.zeros((T,K))
    cdef np.float64_t[:,:] phi = np.zeros((T,K), dtype=np.float64)
    cdef np.ndarray[np.float64_t, ndim=1] totals = np.zeros(T, dtype=np.float64)
    for i in xrange(I):
        #print 'i', i
        phi = np.zeros((T,K), dtype=np.float64)
        #numpy_array = np.asarray(<np.float64_t[:T,:K]> phi)
        #numpy_array[:] = 0.
        v_chs = vert_children[i]
        len_v_chs = v_chs.size
        vp = vert_parent[i]
        totals[:] = 0.
        for t in xrange(T):
            for k in xrange(K):
                for v in xrange(K):
                    if t == 0 and i ==0:
                        # GAMMA
                        #phi[t,k] += log_obs_mat[i,t,k]
                        phi[t,k] += log_gamma[k] + log_obs_mat[i,t,k]
                        if t + 1 < T:
                            phi[t,k] += Q[i,t+1,v] * (log_alpha[k,v])
                            #phi[t,k] += Q[i,t+1,v] * (log_alpha[k,v] + log_obs_mat[i,t+1,v])
                        for j in xrange(len_v_chs):
                            ch_i = v_chs[j]
                            phi[t,k] += Q[ch_i,t,v] * (log_beta[k,v])
                            #phi[t,k] += Q[ch_i,t,v] * (log_beta[k,v] + log_obs_mat[ch_i,t,v])
                    else:
                        if i > 0 and t > 0:
                            # THETA
                            for h in xrange(K):
                                phi[t,k] += Q[vp,t,v] * Q[i,t-1,h] * (log_theta[v,h,k] + log_obs_mat[i,t,k])
                                if t + 1 < T:
                                    phi[t,k] += Q[vp,t+1,v] * Q[i,t+1,h] * (log_theta[v,k,h])
                                    #phi[t,k] += Q[vp,t+1,v] * Q[i,t+1,h] * (log_theta[v,k,h] + log_obs_mat[i,t,h])
                                for j in xrange(len_v_chs):
                                    ch_i = v_chs[j]
                                    #phi[t,k] += Q[ch_i,t,v] * Q[ch_i,t-1,h] * (log_theta[k,h,v] + log_obs_mat[ch_i,t,v])
                                    phi[t,k] += Q[ch_i,t,v] * Q[ch_i,t-1,h] * (log_theta[k,h,v])

                        elif i == 0:
                            # ALPHA
                            phi[t,k] += Q[i,t-1,v] * (log_alpha[v,k] + log_obs_mat[i,t,k])
                            if t + 1 < T:
                                #phi[t,k] += Q[i,t+1,v] * (log_alpha[k,v] + log_obs_mat[i,t+1,v])
                                phi[t,k] += Q[i,t+1,v] * (log_alpha[k,v])
                            for j in xrange(len_v_chs):
                                ch_i = v_chs[j]
                                for h in xrange(K):
                                    phi[t,k] += Q[ch_i,t,v] * Q[ch_i,t-1,h] * (log_theta[k,h,v])
                                    #phi[t,k] += Q[ch_i,t,v] * Q[ch_i,t-1,h] * (log_theta[k,h,v] + log_obs_mat[ch_i, t,v])
                        else:
                            # BETA
                            phi[t,k] += Q[vp,t,v] * (log_beta[v,k] + log_obs_mat[i,t,k])
                            if t + 1 < T:
                                for h in xrange(K):
                                    phi[t,k] += Q[i,t+1,h] * (log_theta[v,k,h])
                                    #phi[t,k] += Q[i,t+1,h] * (log_theta[v,k,h] + log_obs_mat[i,t+1,h])
                            for j in xrange(len_v_chs):
                                ch_i = v_chs[j]
                                #phi[t,k] += Q[ch_i,t,v] * (log_beta[k,v] + log_obs_mat[ch_i,t,v])
                                phi[t,k] += Q[ch_i,t,v] * (log_beta[k,v])

            for k in xrange(K):
                phi[t,k] = exp(phi[t,k])
                totals[t] += phi[t,k]
            for k in xrange(K):
                Q[i, t, k] = phi[t,k] / totals[t]
        ## end t
        ####phi[:] = np.exp(phi)
        #for t in xrange(T):
        #    for k in xrange(K):
        #        Q[i,t,k] = phi[t,k] / totals[t]
    


cpdef mf_update_params(args, renormalize=True):
    cdef np.ndarray[np.int8_t, ndim=3] X
    cdef np.ndarray[np.float64_t, ndim=3] Q, theta
    cdef np.ndarray[np.float64_t, ndim=2] alpha, beta, emit_probs
    cdef np.ndarray[np.float64_t, ndim=1] gamma,
    cdef np.ndarray[np.int8_t, ndim=1] vert_parent
    cdef np.float64_t[:,:,:] log_obs_mat
    cdef np.float64_t pseudocount
    X = args.X
    Q, theta, alpha, beta, gamma, emit_probs, vert_parent, vert_children, log_obs_mat, pseudocount = (args.Q, args.theta,
                                                   args.alpha, args.beta,
                                                   args.gamma, args.emit_probs, args.vert_parent, args.vert_children, args.log_obs_mat, args.pseudocount)
    cdef int I = Q.shape[0], T = Q.shape[1], K = Q.shape[2]
    cdef int L = X.shape[2]
    cdef Py_ssize_t i,t,v,h,k,vp,l
    #print 'mf_update_params'
    theta[:] = pseudocount
    alpha[:] = pseudocount
    beta[:] = pseudocount
    gamma[:] = pseudocount
    emit_probs[:] = pseudocount
    for i in xrange(I):
    #for i in prange(I, nogil=True):
        vp = vert_parent[i]
        for t in xrange(T):
            for k in xrange(K):
                if i==0 and t==0:
                    gamma[k] += Q[i, t, k]
                else:
                    for v in xrange(K):
                        if t == 0:
                            beta[v,k] += Q[i,t,k] * Q[vp,t,v]
                        elif i == 0:
                            alpha[v,k] += Q[i,t,k] * Q[i,t-1,v]
                        else:
                            for h in xrange(K):
                                theta[v,h,k] += Q[i,t,k] * Q[i,t-1,h] * Q[vp,t,v]
                for l in xrange(L):
                    if X[i,t,l]:
                        emit_probs[k, l] += Q[i, t, k]
    if renormalize:
        normalize_trans(theta, alpha, beta, gamma)
    normalize_emit(Q, emit_probs, pseudocount, args, renormalize)
    
    make_log_obs_matrix(args)

def mf_check_convergence(args):
    return (np.abs(args.Q_prev - args.Q).max(axis=0) < 1e-3).all()
