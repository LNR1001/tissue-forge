/*******************************************************************************
 * This file is part of mdcore.
 * Coypright (c) 2012 Pedro Gonnet (pedro.gonnet@durham.ac.uk)
 * Copyright (c) 2022-2024 T.J. Sego
 * 
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 * 
 ******************************************************************************/

// TODO: implement hook for potentials by particles

/* Include configuratin header */
#include <mdcore_config.h>

/* Include some standard header files */
#include <stdlib.h>
#include <stdio.h>
#include <pthread.h>
#include <math.h>
#include <float.h>
#include <string.h>
#include <limits.h>
#include <unordered_map>

#include <cuda_runtime.h>

/* Include some conditional headers. */
#ifdef HAVE_MPI
    #include <mpi.h>
#endif

#include <tfTaskScheduler.h>

/* Force single precision. */
#ifndef FPTYPE_SINGLE
    #define FPTYPE_SINGLE 1
#endif

/* Disable vectorization for the nvcc compiler's sake. */
#undef __SSE__
#undef __SSE2__
#undef __ALTIVEC__
#undef __AVX__

/* Include local headers */
#include <tf_cycle.h>
#include <tf_errs.h>
#include <tf_fptype.h>
#include <tf_lock.h>
#include "tfParticle_cuda.h"
#include <tfSpace_cell.h>
#include <tfSpace.h>
#include <tfTask.h>
#include "tfPotential_cuda.h"
#include "tfBoundaryConditions_cuda.h"
#include <tfFlux.h>
#include <tfEngine.h>
#include "tfRunner_cuda.h"
#include "tfFlux_cuda.h"
#include <tf_port.h>
#include <tfError.h>

#ifndef CPU_TPS
#include <ctime>
#define CPU_TPS CLOCKS_PER_SEC
#endif


using namespace TissueForge;


/* the error macro. */
#define error(id)                           (tf_error(E_FAIL, errs_err_msg[id]))
#define cuda_error()                        (tf_error(E_FAIL, cudaGetErrorString(cudaGetLastError())))
#define cuda_safe_call(f)                   { if(f != cudaSuccess) return cuda_error(); }
#define cuda_safe_call_e(f, _ret_ok)        { if(f != _ret_ok) return cuda_error(); }

/* The parts (non-texture access). */
__constant__ float4* cuda_parts_pos; // x, y, z, radius
__constant__ float3* cuda_parts_vel;
__constant__ int4* cuda_parts_datai; // id, type, flags, clusterId
__constant__ float *cuda_part_states;
static unsigned int engine_cuda_nr_states = 0;

// Boundary conditions
__constant__ cuda::BoundaryConditions cuda_bcs;
static cuda::BoundaryConditions cuda_bcs_dev;

/* Diagonal entries and potential index lookup table. */
__constant__ int *cuda_pind;
__constant__ int *cuda_pind_cluster;
__constant__ int *cuda_pind_bcs[6];

/* The list of tasks. */
__constant__ int2* cuda_cellpair_list_left;
__constant__ int* cuda_cellpair_ind_left;
__constant__ int* cuda_cellpair_count_left;
__constant__ int2* cuda_cellpair_list_right;
__constant__ int* cuda_cellpair_ind_right;
__constant__ int* cuda_cellpair_count_right;

/* Some constants. */
__constant__ float cuda_dt = 0.0f;
__constant__ float cuda_cutoff2 = 0.0f;
__constant__ float cuda_cutoff = 0.0f;
__constant__ float cuda_dscale = 0.0f;
__constant__ float cuda_maxdist = 0.0f;
__constant__ unsigned int cuda_dmaxdist = 0;
__constant__ int cuda_maxtype = 0;
__constant__ unsigned int cuda_nr_cells = 0;

/* Sortlists for the Verlet algorithm. */
__device__ unsigned int *cuda_sortlists = NULL;

/* Cell origins. */
__constant__ float *cuda_corig;

// Cell dimensions
__constant__ float3 *cuda_cdims;

// Cell flags
__constant__ unsigned int *cuda_cflags;

/* Potential energy. */
__device__ float cuda_epot = 0.0f;

/* Timers. */
__device__ float cuda_timers[ tid_count ];

// Fluxes
extern __constant__ int *cuda_fxind;
extern __constant__ struct cuda::Fluxes *cuda_fluxes;

// Potential data

#define ENGINE_CUDA_PIND_WIDTH      3
#define ENGINE_CUDA_POT_WIDTH_ALPHA 3
#define ENGINE_CUDA_POT_WIDTH_DATAF 6
#define ENGINE_CUDA_POT_WIDTH_DATAI 2
#define ENGINE_CUDA_DPD_WIDTH_CF    3
#define ENGINE_CUDA_DPD_WIDTH_DATAF 2
#define ENGINE_CUDA_DPD_WIDTH_DATAI 1

static int *pind_bcs_cuda[engine_maxgpu][6];

static cudaArray *cuda_pot_alpha[engine_maxgpu], *cuda_pot_cluster_alpha[engine_maxgpu], *cuda_pot_bcs_alpha[engine_maxgpu][6];
static cudaArray *cuda_pot_c[engine_maxgpu], *cuda_pot_cluster_c[engine_maxgpu], *cuda_pot_bcs_c[engine_maxgpu][6];
static cudaArray *cuda_pot_dataf[engine_maxgpu], *cuda_pot_cluster_dataf[engine_maxgpu], *cuda_pot_bcs_dataf[engine_maxgpu][6];
static cudaArray *cuda_pot_datai[engine_maxgpu], *cuda_pot_cluster_datai[engine_maxgpu], *cuda_pot_bcs_datai[engine_maxgpu][6];

static cudaTextureObject_t tex_pot_alpha[engine_maxgpu], tex_pot_cluster_alpha[engine_maxgpu], tex_pot_bcs_alpha[engine_maxgpu][6];
static cudaTextureObject_t tex_pot_c[engine_maxgpu], tex_pot_cluster_c[engine_maxgpu], tex_pot_bcs_c[engine_maxgpu][6];
static cudaTextureObject_t tex_pot_dataf[engine_maxgpu], tex_pot_cluster_dataf[engine_maxgpu], tex_pot_bcs_dataf[engine_maxgpu][6];
static cudaTextureObject_t tex_pot_datai[engine_maxgpu], tex_pot_cluster_datai[engine_maxgpu], tex_pot_bcs_datai[engine_maxgpu][6];

__constant__ cudaTextureObject_t cuda_tex_pot_alpha, cuda_tex_pot_cluster_alpha, cuda_tex_pot_bcs_alpha[6];
__constant__ cudaTextureObject_t cuda_tex_pot_c, cuda_tex_pot_cluster_c, cuda_tex_pot_bcs_c[6];
__constant__ cudaTextureObject_t cuda_tex_pot_dataf, cuda_tex_pot_cluster_dataf, cuda_tex_pot_bcs_dataf[6];
__constant__ cudaTextureObject_t cuda_tex_pot_datai, cuda_tex_pot_cluster_datai, cuda_tex_pot_bcs_datai[6];

static cudaArray *cuda_dpd_cfs[engine_maxgpu], *cuda_dpd_cluster_cfs[engine_maxgpu], *cuda_dpd_bcs_cfs[engine_maxgpu][6];
static cudaArray *cuda_dpd_dataf[engine_maxgpu], *cuda_dpd_cluster_dataf[engine_maxgpu], *cuda_dpd_bcs_dataf[engine_maxgpu][6];
static cudaArray *cuda_dpd_datai[engine_maxgpu], *cuda_dpd_cluster_datai[engine_maxgpu], *cuda_dpd_bcs_datai[engine_maxgpu][6];

static cudaTextureObject_t tex_dpd_cfs[engine_maxgpu], tex_dpd_cluster_cfs[engine_maxgpu], tex_dpd_bcs_cfs[engine_maxgpu][6];
static cudaTextureObject_t tex_dpd_dataf[engine_maxgpu], tex_dpd_cluster_dataf[engine_maxgpu], tex_dpd_bcs_dataf[engine_maxgpu][6];
static cudaTextureObject_t tex_dpd_datai[engine_maxgpu], tex_dpd_cluster_datai[engine_maxgpu], tex_dpd_bcs_datai[engine_maxgpu][6];

__constant__ cudaTextureObject_t cuda_tex_dpd_cfs, cuda_tex_dpd_cluster_cfs, cuda_tex_dpd_bcs_cfs[6];
__constant__ cudaTextureObject_t cuda_tex_dpd_dataf, cuda_tex_dpd_cluster_dataf, cuda_tex_dpd_bcs_dataf[6];
__constant__ cudaTextureObject_t cuda_tex_dpd_datai, cuda_tex_dpd_cluster_datai, cuda_tex_dpd_bcs_datai[6];

__constant__ int cuda_pots_max, cuda_pots_cluster_max, cuda_pots_bcs_max[6], cuda_dpds_max, cuda_dpds_cluster_max, cuda_dpds_bcs_max[6];


/* Map sid to shift vectors. */
__constant__ float cuda_shiftn[13*3] = {
     5.773502691896258e-01,  5.773502691896258e-01,  5.773502691896258e-01,
     7.071067811865475e-01,  7.071067811865475e-01,  0.0                  ,
     5.773502691896258e-01,  5.773502691896258e-01, -5.773502691896258e-01,
     7.071067811865475e-01,  0.0                  ,  7.071067811865475e-01,
     1.0                  ,  0.0                  ,  0.0                  ,
     7.071067811865475e-01,  0.0                  , -7.071067811865475e-01,
     5.773502691896258e-01, -5.773502691896258e-01,  5.773502691896258e-01,
     7.071067811865475e-01, -7.071067811865475e-01,  0.0                  ,
     5.773502691896258e-01, -5.773502691896258e-01, -5.773502691896258e-01,
     0.0                  ,  7.071067811865475e-01,  7.071067811865475e-01,
     0.0                  ,  1.0                  ,  0.0                  ,
     0.0                  ,  7.071067811865475e-01, -7.071067811865475e-01,
     0.0                  ,  0.0                  ,  1.0                  ,
     };
__constant__ float cuda_shift[13*3] = {
     1.0,  1.0,  1.0,
     1.0,  1.0,  0.0,
     1.0,  1.0, -1.0,
     1.0,  0.0,  1.0,
     1.0,  0.0,  0.0,
     1.0,  0.0, -1.0,
     1.0, -1.0,  1.0,
     1.0, -1.0,  0.0,
     1.0, -1.0, -1.0,
     0.0,  1.0,  1.0,
     0.0,  1.0,  0.0,
     0.0,  1.0, -1.0,
     0.0,  0.0,  1.0,
    };
    
/* The cell edge lengths and space dimensions. */
__constant__ float cuda_h[3];
__constant__ float cuda_dim[3];


__device__ inline void w_cubic_spline_cuda(float r2, float h, float *result) {
    float r = rsqrt(r2);
    float x = r/h;
    float y;
    
    if(x < 1.f) {
        float x2 = x * x;
        y = 1.f - (3.f / 2.f) * x2 + (3.f / 4.f) * x2 * x;
    }
    else if(x >= 1.f && x < 2.f) {
        float arg = 2.f - x;
        y = (1.f / 4.f) * arg * arg * arg;
    }
    else {
        y = 0.f;
    }
    
    *result = y / (M_PI * h * h * h);
}

__device__ inline void w_cubic_spline_cuda(float r2, float h, float *result, float *_r) {
    float r = sqrt(r2);
    float x = 1.f/(r*h);
    float y;
    
    if(x < 1.f) {
        float x2 = x * x;
        y = 1.f - (3.f / 2.f) * x2 + (3.f / 4.f) * x2 * x;
    }
    else if(x >= 1.f && x < 2.f) {
        float arg = 2.f - x;
        y = (1.f / 4.f) * arg * arg * arg;
    }
    else {
        y = 0.f;
    }
    
    *result = y / (M_PI * h * h * h);
    *_r = r;
}

__device__ inline void w_cubic_spline_cuda_nr(float r2, float h, float *result) {
    float r = sqrt(r2);
    float x = 1.f/(r*h);
    float y;
    
    if(x < 1.f) {
        float x2 = x * x;
        y = 1.f - 1.5f * x2 + 0.75f * x2 * x;
    }
    else if(x >= 1.f && x < 2.f) {
        float arg = 2.f - x;
        y = 0.25f * arg * arg * arg;
    }
    else {
        y = 0.f;
    }
    
    *result = y / (M_PI * h * h * h);
}

/**
 * @brief Copy bulk memory in a strided way.
 *
 * @param dest Pointer to destination memory.
 * @param source Pointer to source memory.
 * @param count Number of bytes to copy, must be a multiple of sizeof(int).
 */
 
__device__ inline void cuda_memcpy(void *dest, void *source, int count) {

    int k;
    int *idest = (int *)dest, *isource = (int *)source;

    int threadID = threadIdx.x;
    
    TIMER_TIC
    
    /* Copy the data in chunks of sizeof(int). */
    for(k = threadID ; k < count/sizeof(int) ; k += blockDim.x)
        idest[k] = isource[k];
        
    TIMER_TOC(tid_memcpy)
        
}

/**
 * @brief Sort the given data w.r.t. the lowest 16 bits in decending order.
 *
 * @param a The array to sort.
 * @param count The number of elements.
 */
 
__device__ inline void cuda_sort_descending(unsigned int *a, int count) {

    
    int i, j, k, threadID = threadIdx.x;
    int hi, lo, ind, jnd;
    unsigned int swap_i, swap_j;

    TIMER_TIC

    /* Sort using normalized bitonic sort. */
    for(k = 1 ; k < count ; k *= 2) {
    
        /* First step. */
        for(i = threadID ;  i < count ; i += blockDim.x) {
            hi = i & ~(k-1); lo = i & (k-1);
            ind = i + hi; jnd = 2*(hi+k) - lo - 1;
            swap_i =(jnd < count) ? a[ind] : 0;
            swap_j =(jnd < count) ? a[jnd] : 0;
            if ((swap_i & 0xffff) <(swap_j & 0xffff)) {
                a[ind] = swap_j;
                a[jnd] = swap_i;
            }
        }
            
        /* Let that last step sink in. */
            __syncthreads();
    
        /* Second step(s). */
        for(j = k/2 ; j > 0 ; j /= 2) {
            for(i = threadID ;  i < count ; i += blockDim.x) {
                hi = i & ~(j-1);
                ind = i + hi; jnd = ind + j;
                swap_i =(jnd < count) ? a[ind] : 0;
                swap_j =(jnd < count) ? a[jnd] : 0;
                if ((swap_i & 0xffff) <(swap_j & 0xffff)) {
                    a[ind] = swap_j;
                    a[jnd] = swap_i;
                }
            }
                __syncthreads();
        }
            
    }
        
    TIMER_TOC(tid_sort)

        
}

HRESULT engine_cuda_texture_init(cudaTextureObject_t *tex, cudaArray_t &arr) {
    cudaResourceDesc resDesc;
    memset(&resDesc, 0, sizeof(cudaResourceDesc));
    resDesc.resType = cudaResourceTypeArray;
    resDesc.res.array.array = arr;

    cudaTextureDesc texDesc;
    memset(&texDesc, 0, sizeof(cudaTextureDesc));
    texDesc.normalizedCoords = false;
    texDesc.filterMode = cudaFilterModePoint;
    texDesc.addressMode[0] = cudaAddressModeClamp;
    texDesc.addressMode[1] = cudaAddressModeClamp;
    texDesc.readMode = cudaReadModeElementType;

    cuda_safe_call(cudaCreateTextureObject(tex, &resDesc, &texDesc, NULL));

    return S_OK;
}

HRESULT engine_cuda_texture_finalize(cudaTextureObject_t tex) {
    cuda_safe_call(cudaDestroyTextureObject(tex));
    
    return S_OK;
}

HRESULT engine_cuda_build_pots_pack(
    Potential **pots, 
    int nr_pots, 
    std::vector<int> &pind, 
    std::vector<float> &pot_alpha, 
    std::vector<float> &pot_c,
    std::vector<float> &pot_dataf, 
    std::vector<int> &pot_datai, 
    std::vector<float> &dpd_cf, 
    std::vector<float> &dpd_dataf, 
    std::vector<int> &dpd_datai, 
    int &max_coeffs, 
    int &max_pots, 
    int &max_dpds, 
    int &num_pots) 
{
    int i, j;
    pind = std::vector<int>(ENGINE_CUDA_PIND_WIDTH * nr_pots, 0);
    std::vector<Potential*> pots_unique(1, 0);

    /* Init the null potential. */
    if((pots_unique[0] = (struct Potential *)alloca(sizeof(struct Potential))) == NULL)
        return error(MDCERR_malloc);
    pots_unique[0]->alpha[0] = pots_unique[0]->alpha[1] = pots_unique[0]->alpha[2] = pots_unique[0]->alpha[3] = 0.0f;
    pots_unique[0]->a = 0.0; pots_unique[0]->b = FLT_MAX;
    pots_unique[0]->flags = POTENTIAL_NONE;
    pots_unique[0]->n = 0;
    if((pots_unique[0]->c = (FPTYPE *)alloca(sizeof(float) * potential_chunk)) == NULL)
        return error(MDCERR_malloc);
    bzero(pots_unique[0]->c, sizeof(float) * potential_chunk);
    
    /* Start by identifying the unique potentials in the engine. */
    max_pots = 1;
    max_dpds = 0;
    num_pots = 0;
    for(i = 0 ; i < nr_pots ; i++) {
    
        /* Skip if there is no potential or no parts of this type. */
        if(pots[i] == NULL)
            continue;
        
        num_pots++;

        /* Check this potential against previous potentials. */
        for(j = 0 ; j < pots_unique.size() && pots[i] != pots_unique[j] ; j++);
        if(j < pots_unique.size())
            continue;

        /* Store this potential and the number of coefficient entries it has. */
        pots_unique.push_back(pots[i]);

        std::vector<Potential*> pots_const;
        if(pots[i]->kind == POTENTIAL_KIND_COMBINATION && pots[i]->flags & POTENTIAL_SUM) {
            pots_const = pots[i]->constituents();
        } 
        else {
            pots_const = {pots[i]};
        }
        int nr_pots_i = 0;
        int nr_dpds_i = 0;
        for(auto &p : pots_const) {
            if(p->kind == POTENTIAL_KIND_DPD) 
                nr_dpds_i++;
            else if(p->kind == POTENTIAL_KIND_POTENTIAL) 
                nr_pots_i++;
        }
        max_dpds = std::max(max_dpds, nr_dpds_i);
        max_pots = std::max(max_pots, nr_pots_i);
    
    }

    std::vector<Potential*> pots_flat_unique(pots_unique.size() * max_pots, 0);
    std::vector<DPDPotential*> dpds_flat_unique(pots_unique.size() * max_dpds, 0);
    max_coeffs = 1;

    for(i = 0; i < pots_unique.size(); i++) {
        std::vector<Potential*> pots_const;
        if(pots_unique[i]->kind == POTENTIAL_KIND_COMBINATION && pots_unique[i]->flags & POTENTIAL_SUM) {
            pots_const = pots_unique[i]->constituents();
        } 
        else {
            pots_const = {pots_unique[i]};
        }
        for(j = 0; j < pots_const.size(); j++) {
            if(pots_const[j]->kind == POTENTIAL_KIND_DPD) 
                dpds_flat_unique[max_dpds * i + j] = (DPDPotential*)pots_const[j];
            else if(pots_const[j]->kind == POTENTIAL_KIND_POTENTIAL) {
                pots_flat_unique[max_pots * i + j] = pots_const[j];
                max_coeffs = std::max(max_coeffs, pots_const[j]->n + 1);
            }
        }
    }

    /* Pack the potential matrices. */
    for(i = 0 ; i < nr_pots ; i++) {
        if(pots[i] != NULL) {
            for(j = 0 ; j < pots_unique.size() && pots_unique[j] != pots[i] ; j++);

            std::vector<Potential*> pots_const;
            if(pots_unique[j]->kind == POTENTIAL_KIND_COMBINATION && pots_unique[j]->flags & POTENTIAL_SUM) {
                pots_const = pots_unique[j]->constituents();
            } 
            else {
                pots_const = {pots_unique[j]};
            }
            int nr_dpds_i = 0;
            int nr_pots_i = 0;
            for(auto &p : pots_const) 
                if(p->kind == POTENTIAL_KIND_DPD) 
                    nr_dpds_i++;
                else if(p->kind == POTENTIAL_KIND_POTENTIAL) 
                    nr_pots_i++;

            pind[i * ENGINE_CUDA_PIND_WIDTH    ] = j;
            pind[i * ENGINE_CUDA_PIND_WIDTH + 1] = nr_pots_i;
            pind[i * ENGINE_CUDA_PIND_WIDTH + 2] = nr_dpds_i;
        }
    }

    pot_alpha = std::vector<float>(pots_flat_unique.size() * ENGINE_CUDA_POT_WIDTH_ALPHA, 0);
    pot_c     = std::vector<float>(pots_flat_unique.size() * potential_chunk * max_coeffs, 0);
    pot_dataf = std::vector<float>(pots_flat_unique.size() * ENGINE_CUDA_POT_WIDTH_DATAF, 0);
    pot_datai = std::vector<int>(pots_flat_unique.size() * ENGINE_CUDA_POT_WIDTH_DATAI, 0);
    dpd_cf    = std::vector<float>(dpds_flat_unique.size() * ENGINE_CUDA_DPD_WIDTH_CF, 0);
    dpd_dataf = std::vector<float>(dpds_flat_unique.size() * ENGINE_CUDA_DPD_WIDTH_DATAF, 0);
    dpd_datai = std::vector<int>(dpds_flat_unique.size() * ENGINE_CUDA_DPD_WIDTH_DATAI, 0);

    // Pack the potentials
    for(i = 0; i < pots_flat_unique.size(); i++) { 
        Potential *p = pots_flat_unique[i];
        if(!p) 
            continue;
        pot_alpha[i * ENGINE_CUDA_POT_WIDTH_ALPHA    ] = p->alpha[0];
        pot_alpha[i * ENGINE_CUDA_POT_WIDTH_ALPHA + 1] = p->alpha[1];
        pot_alpha[i * ENGINE_CUDA_POT_WIDTH_ALPHA + 2] = p->alpha[2];
        for(j = 0; j < potential_chunk * (p->n + 1); j++) 
            pot_c[i * potential_chunk * max_coeffs + j] = p->c[j];
        pot_dataf[i * ENGINE_CUDA_POT_WIDTH_DATAF    ] = p->a;
        pot_dataf[i * ENGINE_CUDA_POT_WIDTH_DATAF + 1] = p->b;
        pot_dataf[i * ENGINE_CUDA_POT_WIDTH_DATAF + 2] = p->r0_plusone;
        pot_dataf[i * ENGINE_CUDA_POT_WIDTH_DATAF + 3] = p->offset[0];
        pot_dataf[i * ENGINE_CUDA_POT_WIDTH_DATAF + 4] = p->offset[1];
        pot_dataf[i * ENGINE_CUDA_POT_WIDTH_DATAF + 5] = p->offset[2];
        pot_datai[i * ENGINE_CUDA_POT_WIDTH_DATAI    ] = p->flags;
        pot_datai[i * ENGINE_CUDA_POT_WIDTH_DATAI + 1] = p->n;
    }
    for(i = 0; i < dpds_flat_unique.size(); i++) {
        DPDPotential *p = dpds_flat_unique[i];
        if(!p) 
            continue;
        dpd_cf[i * ENGINE_CUDA_DPD_WIDTH_CF    ] = p->alpha;
        dpd_cf[i * ENGINE_CUDA_DPD_WIDTH_CF + 1] = p->gamma;
        dpd_cf[i * ENGINE_CUDA_DPD_WIDTH_CF + 2] = p->sigma;
        dpd_dataf[i * ENGINE_CUDA_DPD_WIDTH_DATAF    ] = p->a;
        dpd_dataf[i * ENGINE_CUDA_DPD_WIDTH_DATAF + 1] = p->b;
        dpd_datai[i * ENGINE_CUDA_DPD_WIDTH_DATAI] = p->flags;
    }

    return S_OK;
}

extern "C" HRESULT engine_cuda_boundary_conditions_load(struct engine *e) {

    BoundaryCondition bcs[] = {
        e->boundary_conditions.left, 
        e->boundary_conditions.right, 
        e->boundary_conditions.front, 
        e->boundary_conditions.back, 
        e->boundary_conditions.bottom, 
        e->boundary_conditions.top
    };

    cudaChannelFormatDesc channelDesc_int = cudaCreateChannelDesc<int>();
    cudaChannelFormatDesc channelDesc_float = cudaCreateChannelDesc<float>();

    int pots_bcs_max[6];
    int dpds_bcs_max[6];

    for(int bi = 0; bi < 6; bi++) {

        // GENERATE

        std::vector<int> pind;
        std::vector<float> pot_alpha;
        std::vector<float> pot_c;
        std::vector<float> pot_dataf;
        std::vector<int> pot_datai;
        std::vector<float> dpd_cf;
        std::vector<float> dpd_dataf;
        std::vector<int> dpd_datai;
        int max_coeffs;
        int max_pots;
        int max_dpds;
        int num_pots;

        cuda_safe_call_e(engine_cuda_build_pots_pack(
            bcs[bi].potenntials, e->max_type, 
            pind, pot_alpha, pot_c, pot_dataf, pot_datai, 
            dpd_cf, dpd_dataf, dpd_datai, 
            max_coeffs, max_pots, max_dpds, num_pots), S_OK) ;

        pots_bcs_max[bi] = max_pots;
        dpds_bcs_max[bi] = max_dpds;

        for(int did = 0 ; did < e->nr_devices ; did++) {
            cuda_safe_call(cudaSetDevice(e->devices[did]));

            cuda_safe_call(cudaMalloc(&pind_bcs_cuda[did][bi], sizeof(int) * pind.size()));
            cuda_safe_call(cudaMemcpy(pind_bcs_cuda[did][bi], pind.data(), sizeof(int) * pind.size(), cudaMemcpyHostToDevice));

            cuda_safe_call(cudaMallocArray(&cuda_pot_bcs_alpha[did][bi], &channelDesc_float, ENGINE_CUDA_POT_WIDTH_ALPHA, pot_alpha.size() / ENGINE_CUDA_POT_WIDTH_ALPHA, 0));
            cuda_safe_call(cudaMemcpy2DToArray(cuda_pot_bcs_alpha[did][bi], 0, 0, pot_alpha.data(), sizeof(float) * pot_alpha.size(), sizeof(float) * pot_alpha.size(), 1, cudaMemcpyHostToDevice));
            cuda_safe_call_e(engine_cuda_texture_init(&tex_pot_bcs_alpha[did][bi], cuda_pot_bcs_alpha[did][bi]), S_OK);

            cuda_safe_call(cudaMallocArray(&cuda_pot_bcs_c[did][bi], &channelDesc_float, potential_chunk * max_coeffs, pot_c.size() / (potential_chunk * max_coeffs), 0));
            cuda_safe_call(cudaMemcpy2DToArray(cuda_pot_bcs_c[did][bi], 0, 0, pot_c.data(), sizeof(float) * pot_c.size(), sizeof(float) * pot_c.size(), 1, cudaMemcpyHostToDevice));
            cuda_safe_call_e(engine_cuda_texture_init(&tex_pot_bcs_c[did][bi], cuda_pot_bcs_c[did][bi]), S_OK);

            cuda_safe_call(cudaMallocArray(&cuda_pot_bcs_dataf[did][bi], &channelDesc_float, ENGINE_CUDA_POT_WIDTH_DATAF, pot_dataf.size() / ENGINE_CUDA_POT_WIDTH_DATAF, 0));
            cuda_safe_call(cudaMemcpy2DToArray(cuda_pot_bcs_dataf[did][bi], 0, 0, pot_dataf.data(), sizeof(float) * pot_dataf.size(), sizeof(float) * pot_dataf.size(), 1, cudaMemcpyHostToDevice));
            cuda_safe_call_e(engine_cuda_texture_init(&tex_pot_bcs_dataf[did][bi], cuda_pot_bcs_dataf[did][bi]), S_OK);

            cuda_safe_call(cudaMallocArray(&cuda_pot_bcs_datai[did][bi], &channelDesc_int, ENGINE_CUDA_POT_WIDTH_DATAI, pot_datai.size() / ENGINE_CUDA_POT_WIDTH_DATAI, 0));
            cuda_safe_call(cudaMemcpy2DToArray(cuda_pot_bcs_datai[did][bi], 0, 0, pot_datai.data(), sizeof(int) * pot_datai.size(), sizeof(int) * pot_datai.size(), 1, cudaMemcpyHostToDevice));
            cuda_safe_call_e(engine_cuda_texture_init(&tex_pot_bcs_datai[did][bi], cuda_pot_bcs_datai[did][bi]), S_OK);

            cuda_safe_call(cudaMallocArray(&cuda_dpd_bcs_cfs[did][bi], &channelDesc_float, ENGINE_CUDA_DPD_WIDTH_CF, dpd_cf.size() / ENGINE_CUDA_DPD_WIDTH_CF, 0));
            cuda_safe_call(cudaMemcpy2DToArray(cuda_dpd_bcs_cfs[did][bi], 0, 0, dpd_cf.data(), sizeof(float) * dpd_cf.size(), sizeof(float) * dpd_cf.size(), 1, cudaMemcpyHostToDevice));
            cuda_safe_call_e(engine_cuda_texture_init(&tex_dpd_bcs_cfs[did][bi], cuda_dpd_bcs_cfs[did][bi]), S_OK);

            cuda_safe_call(cudaMallocArray(&cuda_dpd_bcs_dataf[did][bi], &channelDesc_float, ENGINE_CUDA_DPD_WIDTH_DATAF, dpd_dataf.size() / ENGINE_CUDA_DPD_WIDTH_DATAF, 0));
            cuda_safe_call(cudaMemcpy2DToArray(cuda_dpd_bcs_dataf[did][bi], 0, 0, dpd_dataf.data(), sizeof(float) * dpd_dataf.size(), sizeof(float) * dpd_dataf.size(), 1, cudaMemcpyHostToDevice));
            cuda_safe_call_e(engine_cuda_texture_init(&tex_dpd_bcs_dataf[did][bi], cuda_dpd_bcs_dataf[did][bi]), S_OK);

            cuda_safe_call(cudaMallocArray(&cuda_dpd_bcs_datai[did][bi], &channelDesc_int, ENGINE_CUDA_DPD_WIDTH_DATAI, dpd_datai.size() / ENGINE_CUDA_DPD_WIDTH_DATAI, 0));
            cuda_safe_call(cudaMemcpy2DToArray(cuda_dpd_bcs_datai[did][bi], 0, 0, dpd_datai.data(), sizeof(int) * dpd_datai.size(), sizeof(int) * dpd_datai.size(), 1, cudaMemcpyHostToDevice));
            cuda_safe_call_e(engine_cuda_texture_init(&tex_dpd_bcs_datai[did][bi], cuda_dpd_bcs_datai[did][bi]), S_OK);

        }
    }

    for(int did = 0; did < e->nr_devices; did++) {

        cuda_safe_call(cudaSetDevice(e->devices[did]));

        cuda_safe_call(cudaMemcpyToSymbol(cuda_pind_bcs, pind_bcs_cuda[did], 6 * sizeof(int *), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMemcpyToSymbol(cuda_tex_pot_bcs_alpha, &tex_pot_bcs_alpha[did], 6 * sizeof(cudaTextureObject_t), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMemcpyToSymbol(cuda_tex_pot_bcs_c, &tex_pot_bcs_c[did], 6 * sizeof(cudaTextureObject_t), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMemcpyToSymbol(cuda_tex_pot_bcs_dataf, &tex_pot_bcs_dataf[did], 6 * sizeof(cudaTextureObject_t), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMemcpyToSymbol(cuda_tex_pot_bcs_datai, &tex_pot_bcs_datai[did], 6 * sizeof(cudaTextureObject_t), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMemcpyToSymbol(cuda_tex_dpd_bcs_cfs, &tex_dpd_bcs_cfs[did], 6 * sizeof(cudaTextureObject_t), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMemcpyToSymbol(cuda_tex_dpd_bcs_dataf, &tex_dpd_bcs_dataf[did], 6 * sizeof(cudaTextureObject_t), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMemcpyToSymbol(cuda_tex_dpd_bcs_datai, &tex_dpd_bcs_datai[did], 6 * sizeof(cudaTextureObject_t), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMemcpyToSymbol(cuda_pots_bcs_max, pots_bcs_max, 6 * sizeof(int), 0, cudaMemcpyHostToDevice));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_dpds_bcs_max, dpds_bcs_max, 6 * sizeof(int), 0, cudaMemcpyHostToDevice));

        cuda_bcs_dev = cuda::BoundaryConditions(e->boundary_conditions);

        cuda_safe_call(cudaMemcpyToSymbol(cuda_bcs, &cuda_bcs_dev, sizeof(cuda::BoundaryConditions), 0, cudaMemcpyHostToDevice));

    }

    return S_OK;
}

/**
 * @brief Finalize boundary conditions on device. 
 * 
 * @param e The #engine.
 */
HRESULT engine_cuda_boundary_conditions_finalize(struct engine *e) {

    for(int did = 0; did < e->nr_devices; did++) {

        cuda_safe_call(cudaSetDevice(e->devices[did]));

        for(int bi = 0; bi < 6; bi++) {

            cuda_safe_call(cudaFree(pind_bcs_cuda[did][bi]));

            cuda_safe_call_e(engine_cuda_texture_finalize(tex_pot_bcs_alpha[did][bi]), S_OK);
            cuda_safe_call(cudaFreeArray(cuda_pot_bcs_alpha[did][bi]));

            cuda_safe_call_e(engine_cuda_texture_finalize(tex_pot_bcs_c[did][bi]), S_OK);
            cuda_safe_call(cudaFreeArray(cuda_pot_bcs_c[did][bi]));

            cuda_safe_call_e(engine_cuda_texture_finalize(tex_pot_bcs_dataf[did][bi]), S_OK);
            cuda_safe_call(cudaFreeArray(cuda_pot_bcs_dataf[did][bi]));

            cuda_safe_call_e(engine_cuda_texture_finalize(tex_pot_bcs_datai[did][bi]), S_OK);
            cuda_safe_call(cudaFreeArray(cuda_pot_bcs_datai[did][bi]));

            cuda_safe_call_e(engine_cuda_texture_finalize(tex_dpd_bcs_cfs[did][bi]), S_OK);
            cuda_safe_call(cudaFreeArray(cuda_dpd_bcs_cfs[did][bi]));

            cuda_safe_call_e(engine_cuda_texture_finalize(tex_dpd_bcs_dataf[did][bi]), S_OK);
            cuda_safe_call(cudaFreeArray(cuda_dpd_bcs_dataf[did][bi]));

            cuda_safe_call_e(engine_cuda_texture_finalize(tex_dpd_bcs_datai[did][bi]), S_OK);
            cuda_safe_call(cudaFreeArray(cuda_dpd_bcs_datai[did][bi]));

        }

    }

    return S_OK;
}

extern "C" HRESULT cuda::engine_cuda_boundary_conditions_refresh(struct engine *e) {
    
    if(engine_cuda_boundary_conditions_finalize(e) < 0)
        return error(MDCERR_cuda);

    if(engine_cuda_boundary_conditions_load(e) < 0)
        return error(MDCERR_cuda);

    for(int did = 0; did < e->nr_devices; did++) {

        cuda_safe_call(cudaSetDevice(e->devices[did]));

        cuda_safe_call(cudaDeviceSynchronize());

    }

    return S_OK;
}


__device__ void cuda::potential_eval_r_cuda(struct TissueForge::Potential *p, FPTYPE r, FPTYPE *e, FPTYPE *f) {

    int ind, k;
    FPTYPE x, ee, eff, *c;
    
    TIMER_TIC

    /* compute the index */
    ind = fmaxf(0.0f, p->alpha[0] + r * (p->alpha[1] + r * p->alpha[2]));

    /* get the table offset */
    c = &(p->c[ind * potential_chunk]);

    /* adjust x to the interval */
    x = (r - c[0]) * c[1];

    /* compute the potential and its derivative */
    ee = c[2] * x + c[3];
    eff = c[2];
    for(k = 4 ; k < potential_chunk ; k++) {
        eff = eff * x + ee;
        ee = ee * x + c[k];
        }

    /* store the result */
    *e = ee; *f = eff * c[1];

    TIMER_TOC(tid_potential)

}

__device__ void cuda::potential_eval_cuda(struct TissueForge::Potential *p, float r2, float *e, float *f) {

    int ind, k;
    float x, ee, eff, *c, ir, r;
    
    TIMER_TIC
    
    /* Get r for the right type. */
    ir = rsqrtf(r2);
    r = r2*ir;
    
    /* compute the interval index */
    ind = fmaxf(0.0f, p->alpha[0] + r * (p->alpha[1] + r * p->alpha[2]));
    
    /* get the table offset */
    c = &(p->c[ind * potential_chunk]);
    
    /* adjust x to the interval */
    x = (r - c[0]) * c[1];
    
    /* compute the potential and its derivative */
    ee = c[2] * x + c[3];
    eff = c[2];
    #pragma unroll
    for(k = 4 ; k < potential_chunk ; k++) {
        eff = eff * x + ee;
        ee = ee * x + c[k];
    }

    /* store the result */
    *e = ee; *f = eff * c[1] * ir;
        
    TIMER_TOC(tid_potential)
        
}

__device__ void potential_eval_cuda(cuda::PotentialData p, float r2, float *e, float *f) {

    int ind, k;
    float x, ee, eff, *c, ir, r;
    
    TIMER_TIC
    
    /* Get r for the right type. */
    ir = rsqrtf(r2);
    r = r2*ir;
    
    /* compute the interval index */
    ind = fmaxf(0.0f, p.alpha.x + r * (p.alpha.y + r * p.alpha.z));
    
    /* get the table offset */
    c = &(p.c[ind * potential_chunk]);
    
    /* adjust x to the interval */
    x = (r - c[0]) * c[1];
    
    /* compute the potential and its derivative */
    ee = c[2] * x + c[3];
    eff = c[2];
    #pragma unroll
    for(k = 4 ; k < potential_chunk ; k++) {
        eff = eff * x + ee;
        ee = ee * x + c[k];
    }

    /* store the result */
    *e = ee; *f = eff * c[1] * ir;
        
    TIMER_TOC(tid_potential)
        
}

__device__ void potential_eval_cuda(int pind, bool iscluster, float r2, float *e, float *f) {

    int ind, k;
    float x, ee, eff, ir, r;
    
    TIMER_TIC
    
    /* Get r for the right type. */
    ir = rsqrtf(r2);
    r = r2*ir;
    
    /* compute the interval index */
    float3 alpha;
    if(iscluster) {
        alpha.x = tex2D<float>(cuda_tex_pot_cluster_alpha, 0, pind);
        alpha.y = tex2D<float>(cuda_tex_pot_cluster_alpha, 1, pind);
        alpha.z = tex2D<float>(cuda_tex_pot_cluster_alpha, 2, pind);
    } 
    else {
        alpha.x = tex2D<float>(cuda_tex_pot_alpha, 0, pind);
        alpha.y = tex2D<float>(cuda_tex_pot_alpha, 1, pind);
        alpha.z = tex2D<float>(cuda_tex_pot_alpha, 2, pind);
    }
    ind = fmaxf(0.0f, alpha.x + r * (alpha.y + r * alpha.z));
    
    /* get the table offset */
    float c[potential_chunk];
    if(iscluster) {
        for(k = 0; k < potential_chunk; k++) 
            c[k] = tex2D<float>(cuda_tex_pot_cluster_c, ind * potential_chunk + k, pind);
    } 
    else {
        for(k = 0; k < potential_chunk; k++) 
            c[k] = tex2D<float>(cuda_tex_pot_c, ind * potential_chunk + k, pind);
    }
    
    /* adjust x to the interval */
    x = (r - c[0]) * c[1];
    
    /* compute the potential and its derivative */
    ee = c[2] * x + c[3];
    eff = c[2];
    #pragma unroll
    for(k = 4 ; k < potential_chunk ; k++) {
        eff = eff * x + ee;
        ee = ee * x + c[k];
    }

    /* store the result */
    *e = ee; *f = eff * c[1] * ir;
        
    TIMER_TOC(tid_potential)
        
}

/** 
 * @brief Evaluates the given potential at the given point (interpolated).
 *
 * @param p The #potential to be evaluated.
 * @param ri Radius of the ith particle. 
 * @param rj Radius of the jth particle. 
 * @param r2 The radius at which it is to be evaluated, squared.
 * @param e Pointer to a floating-point value in which to store the
 *      interaction energy.
 * @param f Pointer to a floating-point value in which to store the
 *      magnitude of the interaction force divided by r.
 *
 * Note that for efficiency reasons, this function does not check if any
 * of the parameters are @c NULL or if @c sqrt(r2) is within the interval
 * of the #potential @c p.
 */
__device__ inline void potential_eval_ex_cuda (cuda::PotentialData p, float ri, float rj, float r2, float *e, float *f) {

    int ind, k;
    float x, ee, eff, *c, ir, r;
    
    TIMER_TIC
    
    /* Get r for the right type. */
    ir = rsqrtf(r2);
    r = r2*ir;
    
    if(p.flags & POTENTIAL_SCALED) {
        r = r / (ri + rj);
    }
    else if(p.flags & POTENTIAL_SHIFTED) {
        r = r - (ri + rj) + p.w.z;
    }
    
    // cutoff min value, eval at lowest func interpolation.
    r = r < p.w.x ? p.w.x : r;

    if(r > p.w.y) {
        *e = 0.f;
        *f = 0.f;
        return;
    }
    
    /* compute the interval index */
    ind = fmaxf(0.0f, p.alpha.x + r * (p.alpha.y + r * p.alpha.z));

    if(ind > p.n) {
        *e = 0.f;
        *f = 0.f;
        return;
    }
    
    /* get the table offset */
    c = &(p.c[ind * potential_chunk]);
    
    /* adjust x to the interval */
    x = (r - c[0]) * c[1];
    
    /* compute the potential and its derivative */
    ee = c[2] * x + c[3];
    eff = c[2];
    #pragma unroll
    for(k = 4 ; k < potential_chunk ; k++) {
        eff = eff * x + ee;
        ee = ee * x + c[k];
    }

    /* store the result */
    *e = ee; *f = eff * c[1] * ir;

    TIMER_TOC(tid_potential)
        
}

/** 
 * @brief Evaluates the given potential at the given point (interpolated).
 *
 * @param p The #potential to be evaluated.
 * @param ri Radius of the ith particle. 
 * @param rj Radius of the jth particle. 
 * @param r2 The radius at which it is to be evaluated, squared.
 * @param e Pointer to a floating-point value in which to store the
 *      interaction energy.
 * @param f Pointer to a floating-point value in which to store the
 *      magnitude of the interaction force divided by r.
 *
 * Note that for efficiency reasons, this function does not check if any
 * of the parameters are @c NULL or if @c sqrt(r2) is within the interval
 * of the #potential @c p.
 */
__device__ inline void potential_eval_ex_cuda (int pind, bool iscluster, float ri, float rj, float r2, float *e, float *f) {

    int ind, k;
    float x, ee, eff, ir, r;
    
    TIMER_TIC
    
    /* Get r for the right type. */
    ir = rsqrtf(r2);
    r = r2*ir;
    
    int p_flags, n;
    float a, b, r0_plusone;
    if(iscluster) {
        p_flags    = tex2D<int>(cuda_tex_pot_cluster_datai, 0, pind);
        n          = tex2D<int>(cuda_tex_pot_cluster_datai, 1, pind);
        a          = tex2D<float>(cuda_tex_pot_cluster_dataf, 0, pind);
        b          = tex2D<float>(cuda_tex_pot_cluster_dataf, 1, pind);
        r0_plusone = tex2D<float>(cuda_tex_pot_cluster_dataf, 2, pind);
    } 
    else {
        p_flags    = tex2D<int>(cuda_tex_pot_datai, 0, pind);
        n          = tex2D<int>(cuda_tex_pot_datai, 1, pind);
        a          = tex2D<float>(cuda_tex_pot_dataf, 0, pind);
        b          = tex2D<float>(cuda_tex_pot_dataf, 1, pind);
        r0_plusone = tex2D<float>(cuda_tex_pot_dataf, 2, pind);
    }
    
    if(p_flags & POTENTIAL_SCALED) {
        r = r / (ri + rj);
    }
    else if(p_flags & POTENTIAL_SHIFTED) {
        r = r - (ri + rj) + r0_plusone;
    }
    
    // cutoff min value, eval at lowest func interpolation.
    r = r < a ? a : r;

    if(r > b) {
        *e = 0.f;
        *f = 0.f;
        return;
    }
    
    /* compute the interval index */
    float3 alpha;
    if(iscluster) {
        alpha.x = tex2D<float>(cuda_tex_pot_cluster_alpha, 0, pind);
        alpha.y = tex2D<float>(cuda_tex_pot_cluster_alpha, 1, pind);
        alpha.z = tex2D<float>(cuda_tex_pot_cluster_alpha, 2, pind);
    } 
    else {
        alpha.x = tex2D<float>(cuda_tex_pot_alpha, 0, pind);
        alpha.y = tex2D<float>(cuda_tex_pot_alpha, 1, pind);
        alpha.z = tex2D<float>(cuda_tex_pot_alpha, 2, pind);
    }
    
    ind = fmaxf(0.0f, alpha.x + r * (alpha.y + r * alpha.z));

    if(ind > n) {
        *e = 0.f;
        *f = 0.f;
        return;
    }
    
    /* get the table offset */
    float c[potential_chunk];
    if(iscluster) {
        for(k = 0; k < potential_chunk; k++) 
            c[k] = tex2D<float>(cuda_tex_pot_cluster_c, ind * potential_chunk + k, pind);
    } 
    else {
        for(k = 0; k < potential_chunk; k++) 
            c[k] = tex2D<float>(cuda_tex_pot_c, ind * potential_chunk + k, pind);
    }
    
    /* adjust x to the interval */
    x = (r - c[0]) * c[1];
    
    /* compute the potential and its derivative */
    ee = c[2] * x + c[3];
    eff = c[2];
    #pragma unroll
    for(k = 4 ; k < potential_chunk ; k++) {
        eff = eff * x + ee;
        ee = ee * x + c[k];
    }

    /* store the result */
    *e = ee; *f = eff * c[1] * ir;

    TIMER_TOC(tid_potential)
        
}

/** 
 * @brief Evaluates the given potential at the given point (interpolated).
 *
 * @param p The #potential to be evaluated.
 * @param ri Radius of the ith particle. 
 * @param rj Radius of the jth particle. 
 * @param r2 The radius at which it is to be evaluated, squared.
 * @param e Pointer to a floating-point value in which to store the
 *      interaction energy.
 * @param f Pointer to a floating-point value in which to store the
 *      magnitude of the interaction force divided by r.
 *
 * Note that for efficiency reasons, this function does not check if any
 * of the parameters are @c NULL or if @c sqrt(r2) is within the interval
 * of the #potential @c p.
 */
__device__ inline void potential_eval_ex_cuda (int pind, int bid, float ri, float rj, float r2, float *e, float *f) {

    int ind, k;
    float x, ee, eff, ir, r;
    
    TIMER_TIC
    
    /* Get r for the right type. */
    ir = rsqrtf(r2);
    r = r2*ir;
    
    int p_flags      = tex2D<int>(cuda_tex_pot_bcs_datai[bid], 0, pind);
    int n            = tex2D<int>(cuda_tex_pot_bcs_datai[bid], 1, pind);
    float a          = tex2D<float>(cuda_tex_pot_bcs_dataf[bid], 0, pind);
    float b          = tex2D<float>(cuda_tex_pot_bcs_dataf[bid], 1, pind);
    float r0_plusone = tex2D<float>(cuda_tex_pot_bcs_dataf[bid], 2, pind);
    
    if(p_flags & POTENTIAL_SCALED) {
        r = r / (ri + rj);
    }
    else if(p_flags & POTENTIAL_SHIFTED) {
        r = r - (ri + rj) + r0_plusone;
    }
    
    // cutoff min value, eval at lowest func interpolation.
    r = r < a ? a : r;

    if(r > b) {
        *e = 0.f;
        *f = 0.f;
        return;
    }
    
    /* compute the interval index */
    float3 alpha;
    alpha.x = tex2D<float>(cuda_tex_pot_bcs_alpha[bid], 0, pind);
    alpha.y = tex2D<float>(cuda_tex_pot_bcs_alpha[bid], 1, pind);
    alpha.z = tex2D<float>(cuda_tex_pot_bcs_alpha[bid], 2, pind);
    
    ind = fmaxf(0.0f, alpha.x + r * (alpha.y + r * alpha.z));

    if(ind > n) {
        *e = 0.f;
        *f = 0.f;
        return;
    }
    
    /* get the table offset */
    float c[potential_chunk];
    for(k = 0; k < potential_chunk; k++) 
        c[k] = tex2D<float>(cuda_tex_pot_bcs_c[bid], ind * potential_chunk + k, pind);
    
    /* adjust x to the interval */
    x = (r - c[0]) * c[1];
    
    /* compute the potential and its derivative */
    ee = c[2] * x + c[3];
    eff = c[2];
    #pragma unroll
    for(k = 4 ; k < potential_chunk ; k++) {
        eff = eff * x + ee;
        ee = ee * x + c[k];
    }

    /* store the result */
    *e = ee; *f = eff * c[1] * ir;

    TIMER_TOC(tid_potential)
        
}


__device__ inline void dpd_eval_cuda(cuda::DPDPotentialData pot, float ri, float rj, float3 pvi, float3 pvj, float3 dx, float r2, float *e, float *fi) {

    float delta = rsqrtf(cuda_dt);
    
    float r = sqrtf(r2);
    float ro = r < FLT_MIN ? FLT_MIN : r;
    
    r = pot.flags & POTENTIAL_SHIFTED ? r - (ri + rj) : r;

    if(r > pot.w.y) {
        *e = 0.f;
        return;
    }
    r = r >= pot.w.x ? r : pot.w.x;
    
    // unit vector
    float3 unit_vec{dx.x / ro, dx.y / ro, dx.z / ro};

    float3 v{pvi.x - pvj.x, pvi.y - pvj.y, pvi.z - pvj.z};
    
    // conservative force
    float omega_c = r < 0.f ?  1.f : (1 - r / pot.w.y);
    
    float fc = pot.dpd_cfs.x * omega_c;
    
    // dissapative force
    float omega_d = omega_c * omega_c;
    
    float fd = - pot.dpd_cfs.y * omega_d * (unit_vec.x * v.x + unit_vec.y * v.y + unit_vec.z * v.z);
    
    float fr = pot.dpd_cfs.z * omega_c * delta;
    
    float f = fc + fd + fr;
    
    fi[0] += f * unit_vec.x;
    fi[1] += f * unit_vec.y;
    fi[2] += f * unit_vec.z;
    
    // TODO: correct energy
    *e = 0;

}

__device__ inline void dpd_eval_cuda(int pind, bool iscluster, float ri, float rj, float3 pvi, float3 pvj, int pidi, int pidj, float3 dx, float r2, float *e, float *fi) {

    float delta = rsqrtf(cuda_dt);
    
    float r = sqrtf(r2);
    float ro = r < FLT_MIN ? FLT_MIN : r;

    int flags;
    float a, b;

    if(iscluster) {
        flags = tex2D<int>(cuda_tex_dpd_cluster_datai, 0, pind);
        a     = tex2D<float>(cuda_tex_dpd_cluster_dataf, 0, pind);
        b     = tex2D<float>(cuda_tex_dpd_cluster_dataf, 1, pind);
    } 
    else {
        flags = tex2D<int>(cuda_tex_dpd_datai, 0, pind);
        a     = tex2D<float>(cuda_tex_dpd_dataf, 0, pind);
        b     = tex2D<float>(cuda_tex_dpd_dataf, 1, pind);
    }
    
    r = flags & POTENTIAL_SHIFTED ? r - (ri + rj) : r;

    if(r > b) {
        *e = 0.f;
        return;
    }
    r = r >= a ? r : a;

    float alpha, gamma, sigma;

    if(iscluster) {
        alpha = tex2D<float>(cuda_tex_dpd_cluster_cfs, 0, pind);
        gamma = tex2D<float>(cuda_tex_dpd_cluster_cfs, 1, pind);
        sigma = tex2D<float>(cuda_tex_dpd_cluster_cfs, 2, pind);
    } 
    else {
        alpha = tex2D<float>(cuda_tex_dpd_cfs, 0, pind);
        gamma = tex2D<float>(cuda_tex_dpd_cfs, 1, pind);
        sigma = tex2D<float>(cuda_tex_dpd_cfs, 2, pind);
    }
    
    // unit vector
    float3 unit_vec{dx.x / ro, dx.y / ro, dx.z / ro};
    
    float3 v{pvi.x - pvj.x, pvi.y - pvj.y, pvi.z - pvj.z};
    
    // conservative force
    float omega_c = r < 0.f ?  1.f : (1 - r / b);
    
    float fc = alpha * omega_c;
    
    // dissapative force
    float omega_d = omega_c * omega_c;
    
    float fd = - gamma * omega_d * (unit_vec.x * v.x + unit_vec.y * v.y + unit_vec.z * v.z);
    
    float fr = sigma * omega_c * delta;
    
    float f = fc + fd + fr;
    
    fi[0] += f * unit_vec.x;
    fi[1] += f * unit_vec.y;
    fi[2] += f * unit_vec.z;
    
    // TODO: correct energy
    *e = 0;

}


__device__ inline void dpd_boundary_eval_cuda(cuda::DPDPotentialData pot, float ri, float rj, float3 piv, float3 velocity, float3 dx, float r2, float *e, float *force) {

    float delta = rsqrtf(cuda_dt);
    
    float r = sqrtf(r2);
    float ro = r < FLT_MIN ? FLT_MIN : r;
    
    r = pot.flags & POTENTIAL_SHIFTED ? r - (ri + rj) : r;

    if(r > pot.w.y) {
        *e = 0.f;
        return;
    }
    r = r >= pot.w.x ? r : pot.w.x;
    
    // unit vector
    float3 unit_vec{dx.x / ro, dx.y / ro, dx.z / ro};
    
    float3 v{piv.x - velocity.x, piv.y - velocity.y, piv.z - velocity.z};
    
    // conservative force
    float omega_c = r < 0.f ?  1.f : (1 - r / pot.w.y);
    
    float fc = pot.dpd_cfs.x * omega_c;
    
    // dissapative force
    float omega_d = omega_c * omega_c;
    
    float fd = - pot.dpd_cfs.y * omega_d * (unit_vec.x * v.x + unit_vec.y * v.y + unit_vec.z * v.z);
    
    float fr = pot.dpd_cfs.z * omega_c * delta;
    
    float f = fc + fd + fr;
    
    force[0] += f * unit_vec.x;
    force[1] += f * unit_vec.y;
    force[2] += f * unit_vec.z;
    
    // TODO: correct energy
    *e = 0;

}

__device__ inline void dpd_boundary_eval_cuda(int pind, int bid, float ri, float rj, float3 piv, float3 velocity, float3 dx, float r2, float *e, float *force) {

    float delta = rsqrtf(cuda_dt);
    
    float r = sqrtf(r2);
    float ro = r < FLT_MIN ? FLT_MIN : r;
    
    int flags = tex2D<int>(cuda_tex_dpd_bcs_datai[bid], 0, pind);
    float a = tex2D<float>(cuda_tex_dpd_bcs_dataf[bid], 0, pind);
    float b = tex2D<float>(cuda_tex_dpd_bcs_dataf[bid], 1, pind);;
    
    r = flags & POTENTIAL_SHIFTED ? r - (ri + rj) : r;

    if(r > b) {
        *e = 0.f;
        return;
    }
    r = r >= a ? r : a;

    float3 dpd_cfs;
    dpd_cfs.x = tex2D<float>(cuda_tex_dpd_bcs_cfs[bid], 0, pind);
    dpd_cfs.y = tex2D<float>(cuda_tex_dpd_bcs_cfs[bid], 1, pind);
    dpd_cfs.z = tex2D<float>(cuda_tex_dpd_bcs_cfs[bid], 2, pind);
    
    // unit vector
    float3 unit_vec{dx.x / ro, dx.y / ro, dx.z / ro};
    
    float3 v{piv.x - velocity.x, piv.y - velocity.y, piv.z - velocity.z};
    
    // conservative force
    float omega_c = r < 0.f ?  1.f : (1 - r / b);
    
    float fc = dpd_cfs.x * omega_c;
    
    // dissapative force
    float omega_d = omega_c * omega_c;
    
    float fd = - dpd_cfs.y * omega_d * (unit_vec.x * v.x + unit_vec.y * v.y + unit_vec.z * v.z);
    
    float fr = dpd_cfs.z * omega_c * delta;
    
    float f = fc + fd + fr;
    
    force[0] += f * unit_vec.x;
    force[1] += f * unit_vec.y;
    force[2] += f * unit_vec.z;
    
    // TODO: correct energy
    *e = 0;

}


// Underlying evaluation call
__device__ inline void _potential_eval_super_ex_cuda_p(int pind, 
                                                    bool iscluster, 
                                                    float ri, 
                                                    float rj, 
                                                    int pidi, 
                                                    int pidj, 
                                                    float3 dx, 
                                                    float r2, 
                                                    float *epot, 
                                                    float *fi) 
{
    int p_flags = tex2D<int>(iscluster ? cuda_tex_pot_cluster_datai : cuda_tex_pot_datai, 0, pind);
    if(p_flags & POTENTIAL_PERIODIC) {
        // Assuming elsewhere there's a corresponding potential in the opposite direction
        cudaTextureObject_t tex = iscluster ? cuda_tex_pot_cluster_dataf : cuda_tex_pot_dataf;
        float3 offset;
        offset.x = tex2D<float>(tex, 3, pind);
        offset.y = tex2D<float>(tex, 4, pind);
        offset.z = tex2D<float>(tex, 5, pind);
        dx.x -= offset.x;
        dx.y -= offset.y;
        dx.z -= offset.z;
        r2 = dx.x * dx.x + dx.y * dx.y + dx.z * dx.z;
    }
    
    float e, f;

    /* update the forces if part in range */
    potential_eval_ex_cuda(pind, iscluster, ri, rj, r2, &e, &f);

    fi[0] -= f * dx.x;
    fi[1] -= f * dx.y;
    fi[2] -= f * dx.z;
    
    /* tabulate the energy */
    *epot += e;
}


// Underlying evaluation call
__device__ inline void _potential_eval_super_ex_cuda_d(int pind, 
                                                    bool iscluster,
                                                    float ri, 
                                                    float rj, 
                                                    float3 vi, 
                                                    float3 vj, 
                                                    int pidi, 
                                                    int pidj, 
                                                    float3 dx, 
                                                    float r2, 
                                                    float *epot, 
                                                    float *fi) 
{
    float e;

    /* update the forces if part in range */
    dpd_eval_cuda(pind, iscluster, ri, rj, vi, vj, pidi, pidj, dx, r2, &e, fi);
    
    *epot += e;
}

template <bool iscluster> 
__device__ inline 
void potential_eval_super_ex_cuda(int pind, 
                                  int nr_pots, 
                                  int nr_dpds, 
                                  float ri, 
                                  float rj, 
                                  int pidi, 
                                  int pidj, 
                                  float3 dx, 
                                  float r2, 
                                  float *epot, 
                                  float *fi) 
{

    if(iscluster) {
        int stride = cuda_dpds_cluster_max;
        if(nr_dpds > 0) {
            float3 vi = cuda_parts_vel[pidi];
            float3 vj = cuda_parts_vel[pidj];
            for(int i = 0; i < nr_dpds; i++) 
                _potential_eval_super_ex_cuda_d(stride * pind + i, true, ri, rj, vi, vj, pidi, pidj, dx, r2, epot, fi);
        }

        stride = cuda_pots_cluster_max;
        for(int i = 0; i < nr_pots; i++) {
            _potential_eval_super_ex_cuda_p(stride * pind + i, true, ri, rj, pidi, pidj, dx, r2, epot, fi);
        }
    } 
    else {
        int stride = cuda_dpds_max;
        if(nr_dpds > 0) {
            float3 vi = cuda_parts_vel[pidi];
            float3 vj = cuda_parts_vel[pidj];
            for(int i = 0; i < nr_dpds; i++) 
                _potential_eval_super_ex_cuda_d(stride * pind + i, false, ri, rj, vi, vj, pidi, pidj, dx, r2, epot, fi);
        }

        stride = cuda_pots_max;
        for(int i = 0; i < nr_pots; i++) {
            _potential_eval_super_ex_cuda_p(stride * pind + i, false, ri, rj, pidi, pidj, dx, r2, epot, fi);
        }
    }

}

__device__ inline void _boundary_eval_cuda_ex_cuda_p(int pind, 
                                                     int bid, 
                                                     float ri, 
                                                     int pid, 
                                                     cuda::BoundaryCondition bc, 
                                                     float3 dx, 
                                                     float r2, 
                                                     float *epot, 
                                                     float *force) 
{
    float e, f;

    /* update the forces if part in range */
    potential_eval_ex_cuda(pind, bid, ri, bc.radius, r2, &e, &f);

    force[0] -= f * dx.x;
    force[1] -= f * dx.y;
    force[2] -= f * dx.z;
    
    /* tabulate the energy */
    *epot += e;
}


__device__ inline 
void _boundary_eval_cuda_ex_cuda_d(int pind, 
                                   int bid, 
                                   float ri, 
                                   float3 vi, 
                                   int pid, 
                                   cuda::BoundaryCondition bc, 
                                   float3 dx, 
                                   float r2, 
                                   float *epot, 
                                   float *force) 
{
    float e;
    
    /* update the forces if part in range */
    dpd_boundary_eval_cuda(pind, bid, ri, bc.radius, vi, bc.velocity, dx, r2, &e, force);
    
    *epot += e;
}

__device__ inline 
void boundary_eval_cuda_ex_cuda(int pind, 
                                int nr_pots, 
                                int nr_dpds, 
                                int bid, 
                                float ri, 
                                int pid, 
                                cuda::BoundaryCondition bc, 
                                float3 dx, 
                                float r, 
                                float *epot, 
                                float *force) 
{
    float r2 = r * r;

    if(nr_dpds > 0) {
        float3 vi = cuda_parts_vel[pid];
        int stride = cuda_dpds_bcs_max[bid];
        for(int i = 0; i < nr_dpds; i++) {
            _boundary_eval_cuda_ex_cuda_d(stride * pind + i, bid, ri, vi, pid, bc, dx, r2, epot, force);
        }
    }

    int stride = cuda_pots_bcs_max[bid];
    for(int i = 0; i < nr_pots; i++) {
        _boundary_eval_cuda_ex_cuda_p(stride * pind + i, bid, ri, pid, bc, dx, r2, epot, force);
    }
}

__device__ 
void boundary_eval_cuda(float4 px, int pid, int typeId, float3 cell_dim, unsigned int cell_flags, float *force, float *epot) {
    
    float r;
    cuda::BoundaryCondition *bcs = cuda_bcs.bcs;
    
    if(cell_flags & cell_active_left) {
        int pind    = cuda_pind_bcs[0][ENGINE_CUDA_PIND_WIDTH * typeId    ];
        int nr_pots = cuda_pind_bcs[0][ENGINE_CUDA_PIND_WIDTH * typeId + 1];
        int nr_dpds = cuda_pind_bcs[0][ENGINE_CUDA_PIND_WIDTH * typeId + 2];
        if(nr_pots + nr_dpds > 0) {
            r = px.x;
            float3 dx{r, 0.f, 0.f};
            boundary_eval_cuda_ex_cuda(pind, nr_pots, nr_dpds, 0, px.w, pid, bcs[0], dx, r, epot, force);
        }
    }
    
    if(cell_flags & cell_active_right) {
        int pind    = cuda_pind_bcs[1][ENGINE_CUDA_PIND_WIDTH * typeId    ];
        int nr_pots = cuda_pind_bcs[1][ENGINE_CUDA_PIND_WIDTH * typeId + 1];
        int nr_dpds = cuda_pind_bcs[1][ENGINE_CUDA_PIND_WIDTH * typeId + 2];
        if(nr_pots + nr_dpds > 0) {
            r = cell_dim.x - px.x;
            float3 dx{-r, 0.f, 0.f};
            boundary_eval_cuda_ex_cuda(pind, nr_pots, nr_dpds, 1, px.w, pid, bcs[1], dx, r, epot, force);
        }
    }
    
    if(cell_flags & cell_active_front) {
        int pind    = cuda_pind_bcs[2][ENGINE_CUDA_PIND_WIDTH * typeId    ];
        int nr_pots = cuda_pind_bcs[2][ENGINE_CUDA_PIND_WIDTH * typeId + 1];
        int nr_dpds = cuda_pind_bcs[2][ENGINE_CUDA_PIND_WIDTH * typeId + 2];
        if(nr_pots + nr_dpds > 0) {
            r = px.y;
            float3 dx{0.f, r, 0.f};
            boundary_eval_cuda_ex_cuda(pind, nr_pots, nr_dpds, 2, px.w, pid, bcs[2], dx, r, epot, force);
        }
    }
    
    if(cell_flags & cell_active_back) {
        int pind    = cuda_pind_bcs[3][ENGINE_CUDA_PIND_WIDTH * typeId    ];
        int nr_pots = cuda_pind_bcs[3][ENGINE_CUDA_PIND_WIDTH * typeId + 1];
        int nr_dpds = cuda_pind_bcs[3][ENGINE_CUDA_PIND_WIDTH * typeId + 2];
        if(nr_pots + nr_dpds > 0) {
            r = cell_dim.y - px.y;
            float3 dx{0.f, -r, 0.f};
            boundary_eval_cuda_ex_cuda(pind, nr_pots, nr_dpds, 3, px.w, pid, bcs[3], dx, r, epot, force);
        }
    }
    
    if(cell_flags & cell_active_bottom) {
        int pind    = cuda_pind_bcs[4][ENGINE_CUDA_PIND_WIDTH * typeId    ];
        int nr_pots = cuda_pind_bcs[4][ENGINE_CUDA_PIND_WIDTH * typeId + 1];
        int nr_dpds = cuda_pind_bcs[4][ENGINE_CUDA_PIND_WIDTH * typeId + 2];
        if(nr_pots + nr_dpds > 0) {
            r = px.z;
            float3 dx{0.f, 0.f, r};
            boundary_eval_cuda_ex_cuda(pind, nr_pots, nr_dpds, 4, px.w, pid, bcs[4], dx, r, epot, force);
        }
    }
    
    if(cell_flags & cell_active_top) {
        int pind    = cuda_pind_bcs[5][ENGINE_CUDA_PIND_WIDTH * typeId    ];
        int nr_pots = cuda_pind_bcs[5][ENGINE_CUDA_PIND_WIDTH * typeId + 1];
        int nr_dpds = cuda_pind_bcs[5][ENGINE_CUDA_PIND_WIDTH * typeId + 2];
        if(nr_pots + nr_dpds > 0) {
            r = cell_dim.z - px.z;
            float3 dx{0.f, 0.f, -r};
            boundary_eval_cuda_ex_cuda(pind, nr_pots, nr_dpds, 5, px.w, pid, bcs[5], dx, r, epot, force);
        }
    }

}


__device__ inline 
void flux_fick_cuda(cuda::Flux flux, int i, float si, float sj, float *result) {
    *result *= flux.coef[i] * (si - sj);
}

__device__ inline 
void flux_secrete_cuda(cuda::Flux flux, int i, float si, float sj, float *result) {
    float q = flux.coef[i] * (si - flux.target[i]);
    float scale = q > 0.f;  // forward only, 1 if > 0, 0 if < 0.
    *result *= scale * q;
}

__device__ inline 
void flux_uptake_cuda(cuda::Flux flux, int i, float si, float sj, float *result) {
    float q = flux.coef[i] * (flux.target[i] - sj) * si;
    float scale = q > 0.f;
    *result *= scale * q;
}

__device__ inline 
void flux_eval_ex_cuda(cuda::Fluxes fluxes, float r, float *states_i, float *states_j, int type_i, int type_j, float *qvec_i) {

    // Do calculations

    float ssi, ssj;
    float q;
    
    cuda::Flux flux = fluxes.fluxes[0];
    float term = 1. - r / cuda_cutoff;
    term = term * term;

    int qind;
    
    for(int i = 0; i < flux.size; ++i) {

        if(type_i == flux.type_ids[i].a) {
            qind = flux.indices_a[i];
            ssi = states_i[qind];
            ssj = states_j[flux.indices_b[i]];
            q = - term;
        }
        else {
            qind = flux.indices_b[i];
            ssi = states_j[flux.indices_a[i]];
            ssj = states_i[qind];
            q = term;
        }

        switch(flux.kinds[i]) {
            case FLUX_FICK:
                flux_fick_cuda(flux, i, ssi, ssj, &q);
                break;
            case FLUX_SECRETE:
                flux_secrete_cuda(flux, i, ssi, ssj, &q);
                break;
            case FLUX_UPTAKE:
                flux_uptake_cuda(flux, i, ssi, ssj, &q);
                break;
            default:
                __builtin_unreachable();
        }

        qvec_i[qind] += q - 0.5 * flux.decay_coef[i] * states_i[qind];
    }
}

__device__ inline 
void flux_eval_ex_cuda(cuda::Fluxes fluxes, float r, float *states_i, float *states_j, int type_i, int type_j, float *qvec_i, float *qvec_j) {

    // Do calculations
    
    cuda::Flux flux = fluxes.fluxes[0];
    float term = 1. - r / cuda_cutoff;
    term = term * term;

    float *qi, *qj, *si, *sj;
    
    for(int i = 0; i < flux.size; ++i) {

        if(type_i == flux.type_ids[i].a) {
            si = states_i;
            sj = states_j;
            qi = qvec_i;
            qj = qvec_j;
        }
        else {
            si = states_j;
            sj = states_i;
            qi = qvec_j;
            qj = qvec_i;
        }
        
        float ssi = si[flux.indices_a[i]];
        float ssj = sj[flux.indices_b[i]];
        float q =  term;
        float mult;
        
        switch(flux.kinds[i]) {
            case FLUX_FICK:
                flux_fick_cuda(flux, i, ssi, ssj, &mult);
                q *= mult;
                break;
            case FLUX_SECRETE:
                flux_secrete_cuda(flux, i, ssi, ssj, &mult);
                q *= mult;
                break;
            case FLUX_UPTAKE:
                flux_uptake_cuda(flux, i, ssi, ssj, &mult);
                q *= mult;
                break;
            default:
                __builtin_unreachable();
        }
        
        float half_decay = flux.decay_coef[i] * 0.5;
        qi[flux.indices_a[i]] -= q + half_decay * ssi;
        qj[flux.indices_b[i]] += q - half_decay * ssj;
    }
}


/**
 * @brief Compute the pairwise interactions for the given pair on a CUDA device.
 *
 * @param icid Array of parts in the first cell.
 * @param count_i Number of parts in the first cell.
 * @param icjd Array of parts in the second cell.
 * @param count_j Number of parts in the second cell.
 * @param pshift A pointer to an array of three floating point values containing
 *      the vector separating the centers of @c cell_i and @c cell_j.
 * @param cid Part buffer in local memory.
 * @param cjd Part buffer in local memory.
 *
 * @sa #runner_dopair.
 */
__device__ inline void runner_dosort_cuda(float4* parts_pos, int count_i, unsigned int *sort_i, int sid) {
    
    TIMER_TIC
    
    /* Get the shift vector from the sid. */
    float shift[3];
    shift[0] = cuda_shift[ 3*sid + 0 ] * cuda_h[0];
    shift[1] = cuda_shift[ 3*sid + 1 ] * cuda_h[1];
    shift[2] = cuda_shift[ 3*sid + 2 ] * cuda_h[2];

    /* Pre-compute the inverse norm of the shift. */
    float nshift = sqrtf(shift[0]*shift[0] + shift[1]*shift[1] + shift[2]*shift[2]);
    shift[0] = cuda_shiftn[ 3*sid + 0 ];
    shift[1] = cuda_shiftn[ 3*sid + 1 ];
    shift[2] = cuda_shiftn[ 3*sid + 2 ];

    /* Pack the parts into the sort arrays. */
    for(int k = threadIdx.x ; k < count_i ; k += blockDim.x) {
        float4 pix = parts_pos[ k ];
        sort_i[k] =(k << 16) | (unsigned int)(cuda_dscale * (nshift + pix.x*shift[0] + pix.y*shift[1] + pix.z*shift[2]));
    }

    TIMER_TOC(tid_pack)
    __syncthreads();
    /* Sort using normalized bitonic sort. */
    cuda_sort_descending(sort_i, count_i);

}

/**
 * @brief Compute the pairwise interactions for the given pair on a CUDA device.
 *
 * @param icid Array of parts in the first cell.
 * @param count_i Number of parts in the first cell.
 * @param icjd Array of parts in the second cell.
 * @param count_j Number of parts in the second cell.
 * @param pshift A pointer to an array of three floating point values containing
 *      the vector separating the centers of @c cell_i and @c cell_j.
 * @param cid Part buffer in local memory.
 * @param cjd Part buffer in local memory.
 *
 * @sa #runner_dopair.
 */
 __device__ void runner_dopair_left_cuda(
    int ind_i, int count_i, 
    int ind_j, int count_j, 
    float4* parts_pos_i, int4* parts_datai_i, 
    float4* parts_pos_j, int4* parts_datai_j, 
    float *forces_i, 
    unsigned int *sort_i, unsigned int *sort_j, 
    float *shift, unsigned int dshift, float *epot_global
) {
    float epot = 0.0f;
    
    TIMER_TIC

    for(int i = threadIdx.x ; i < count_i ;  i += blockDim.x) {

        unsigned int di = (sort_i[i]&0xffff);

        /* Get a direct pointer on the pjdth part in cell_j. */
        int spid = sort_i[i] >> 16;
        int pidi = ind_i + spid;
        float4 pix = parts_pos_i[spid];
        pix.x -= shift[0]; pix.y -= shift[1]; pix.z -= shift[2];
        int4 pdatai_i = parts_datai_i[spid];
        int pioff = pdatai_i.y * cuda_maxtype;
        int flagsi = pdatai_i.z;
        int clusterIdi = pdatai_i.w;
        float pif[] = {0.0f, 0.0f, 0.0f, 0.0f};

        /* Loop over the particles in cell_j. */
        for(int k = count_j-1 ; k >= 0 && (sort_j[k]&0xffff) + dshift < cuda_dmaxdist + di ; k--) {
                 
            /* Get a handle on the wrapped particle pid in cell_i. */

            int spjd = sort_j[k] >> 16;

            /* Compute the radius between pi and pj. */
            float4 pjx = parts_pos_j[spjd];
            float3 dx{pix.x - pjx.x, pix.y - pjx.y, pix.z - pjx.z};
            float r2 = dx.x * dx.x + dx.y * dx.y + dx.z * dx.z;

            if(r2 < cuda_cutoff2) {

                float number_density;
                
                w_cubic_spline_cuda_nr(r2, cuda_cutoff, &number_density);

                pif[3] += number_density;

                int pind, nr_pots, nr_dpds;
                int4 pdatai_j = parts_datai_j[spjd];
                int pjoff = ENGINE_CUDA_PIND_WIDTH * (pioff + pdatai_j.y);
                bool iscluster = flagsi & PARTICLE_BOUND && pdatai_j.z & PARTICLE_BOUND && clusterIdi == pdatai_j.w;

                if(iscluster) {
                    pind    = cuda_pind_cluster[pjoff    ];
                    nr_pots = cuda_pind_cluster[pjoff + 1];
                    nr_dpds = cuda_pind_cluster[pjoff + 2];
                }
                else {
                    pind    = cuda_pind[pjoff    ];
                    nr_pots = cuda_pind[pjoff + 1];
                    nr_dpds = cuda_pind[pjoff + 2];
                }

                if(pind != 0) {

                    float ee = 0.0f;
                    int pidj = ind_j + spjd;

                    /* Interact particles pi and pj. */
                    if(iscluster) 
                        potential_eval_super_ex_cuda<true>(pind, nr_pots, nr_dpds, pix.w, pjx.w, pidi, pidj, dx, r2, &ee, pif);
                    else 
                        potential_eval_super_ex_cuda<false>(pind, nr_pots, nr_dpds, pix.w, pjx.w, pidi, pidj, dx, r2, &ee, pif);

                    /* Store the interaction energy. */
                    epot += ee;
                }
            }

        } /* loop over parts in cell_i. */

        /* Update the force on pj. */
        #pragma unroll
        for(int k = 0 ; k < 4 ; k++)
        	forces_i[4*spid + k] += pif[k];
        
    } /* loop over the particles in cell_j. */
        
    /* Store the potential energy. */
    *epot_global += epot;
        
    TIMER_TOC(tid_pair)
    
}

/**
 * @brief Compute the pairwise interactions for the given pair on a CUDA device.
 *
 * @param icid Array of parts in the first cell.
 * @param count_i Number of parts in the first cell.
 * @param icjd Array of parts in the second cell.
 * @param count_j Number of parts in the second cell.
 * @param pshift A pointer to an array of three floating point values containing
 *      the vector separating the centers of @c cell_i and @c cell_j.
 * @param cid Part buffer in local memory.
 * @param cjd Part buffer in local memory.
 *
 * @sa #runner_dopair.
 */
 __device__ void runner_dopair_right_cuda(
    int ind_i, int count_i, 
    int ind_j, int count_j, 
    float4* parts_pos_i, int4* parts_datai_i, 
    float4* parts_pos_j, int4* parts_datai_j, 
    float *forces_i, 
    unsigned int *sort_i, unsigned int *sort_j, 
    float *shift, unsigned int dshift, float *epot_global
) {
    float epot = 0.0f;
    
    TIMER_TIC

    for(int i = threadIdx.x ; i < count_i ;  i += blockDim.x) {

        unsigned int di = (sort_i[i]&0xffff);

        /* Get a direct pointer on the pjdth part in cell_j. */
        int spid = sort_i[i] >> 16;
        int pidi = ind_i + spid;
        float4 pix = parts_pos_i[spid];
        pix.x += shift[0]; pix.y += shift[1]; pix.z += shift[2];
        int4 pdatai_i = parts_datai_i[spid];
        int pioff = pdatai_i.y * cuda_maxtype;
        int flagsi = pdatai_i.z;
        int clusterIdi = pdatai_i.w;
        float pif[] = {0.0f, 0.0f, 0.0f, 0.0f};

        /* Loop over the particles in cell_j. */
        for(int k = 0 ; k < count_j && di + dshift <= cuda_dmaxdist + (sort_j[k]&0xffff) ; k++) {
                 
            /* Get a handle on the wrapped particle pid in cell_i. */

            int spjd = sort_j[k] >> 16;

            /* Compute the radius between pi and pj. */
            float4 pjx = parts_pos_j[spjd];
            float3 dx{pix.x - pjx.x, pix.y - pjx.y, pix.z - pjx.z};
            float r2 = dx.x * dx.x + dx.y * dx.y + dx.z * dx.z;

            if(r2 < cuda_cutoff2) {

                float number_density;
                
                w_cubic_spline_cuda_nr(r2, cuda_cutoff, &number_density);

                pif[3] += number_density;

                int pind, nr_pots, nr_dpds;
                int4 pdatai_j = parts_datai_j[spjd];
                int pjoff = ENGINE_CUDA_PIND_WIDTH * (pioff + pdatai_j.y);
                bool iscluster = flagsi & PARTICLE_BOUND && pdatai_j.z & PARTICLE_BOUND && clusterIdi == pdatai_j.w;

                if(iscluster) {
                    pind    = cuda_pind_cluster[pjoff    ];
                    nr_pots = cuda_pind_cluster[pjoff + 1];
                    nr_dpds = cuda_pind_cluster[pjoff + 2];
                }
                else {
                    pind    = cuda_pind[pjoff    ];
                    nr_pots = cuda_pind[pjoff + 1];
                    nr_dpds = cuda_pind[pjoff + 2];
                }

                if(pind != 0) {

                    float ee = 0.0f;
                    int pidj = ind_j + spjd;

                    /* Interact particles pi and pj. */
                    if(iscluster) 
                        potential_eval_super_ex_cuda<true>(pind, nr_pots, nr_dpds, pix.w, pjx.w, pidi, pidj, dx, r2, &ee, pif);
                    else 
                        potential_eval_super_ex_cuda<false>(pind, nr_pots, nr_dpds, pix.w, pjx.w, pidi, pidj, dx, r2, &ee, pif);

                    /* Store the interaction energy. */
                    epot += ee;
                }
            }

        } /* loop over parts in cell_i. */

        /* Update the force on pj. */
        #pragma unroll
        for(int k = 0 ; k < 4 ; k++)
        	forces_i[4*spid + k] += pif[k];
        
    } /* loop over the particles in cell_j. */
        
    /* Store the potential energy. */
    *epot_global += epot;
        
    TIMER_TOC(tid_pair)
    
}

/**
 * @brief Compute the pairwise interactions for the given pair on a CUDA device.
 *
 * @param icid Array of parts in the first cell.
 * @param count_i Number of parts in the first cell.
 * @param icjd Array of parts in the second cell.
 * @param count_j Number of parts in the second cell.
 * @param pshift A pointer to an array of three floating point values containing
 *      the vector separating the centers of @c cell_i and @c cell_j.
 * @param cid Part buffer in local memory.
 * @param cjd Part buffer in local memory.
 *
 * @sa #runner_dopair.
 */
__device__ void runner_dopair_state_left_cuda(
    int ind_i, float *states_i, int count_i, 
    int ind_j, float *states_j, int count_j, 
    float4* parts_pos_i, int4* parts_datai_i, 
    float4* parts_pos_j, int4* parts_datai_j, 
    float *fluxes_i, 
    unsigned int *sort_i, unsigned int *sort_j, 
    float *shift, unsigned int dshift, unsigned int nr_states
) {
    
    TIMER_TIC
    
    for(int i = threadIdx.x ; i < count_i ;  i += blockDim.x) {

        unsigned int di = (sort_i[i]&0xffff);
        /* Get a direct pointer on the pjdth part in cell_j. */
        int spid = sort_i[i] >> 16;
        float4 pix = parts_pos_i[spid];
        pix.x -= shift[0]; pix.y -= shift[1]; pix.z -= shift[2];
        int typeIdi = parts_datai_i[spid].y;
        int pioff = typeIdi * cuda_maxtype;

        float pifx[TF_SIMD_SIZE];
        memset(pifx, 0.f, nr_states * sizeof(float));
        float *pis = &states_i[nr_states * spid];

        /* Loop over the particles in cell_j. */
        for(int k = count_j-1 ; k >= 0 && (sort_j[k]&0xffff) + dshift < cuda_dmaxdist + di ; k--) {
                 
            /* Get a handle on the wrapped particle pid in cell_i. */

            int spjd = sort_j[k] >> 16;

            /* Compute the radius between pi and pj. */
            float4 pjx = parts_pos_j[spjd];
            float r2 = 0.0f, dx;
            dx = pix.x - pjx.x; r2 += dx * dx;
            dx = pix.y - pjx.y; r2 += dx * dx;
            dx = pix.z - pjx.z; r2 += dx * dx;

            if(r2 >= cuda_cutoff2) {
                continue;
            }

            int typeIdj = parts_datai_j[spjd].y;
            int fxind = cuda_fxind[pioff + typeIdj];
            if(fxind != 0) {
                flux_eval_ex_cuda(cuda_fluxes[fxind], sqrtf(r2), pis, &states_j[nr_states * spjd], typeIdi, typeIdj, pifx);
            }

        } /* loop over parts in cell_i. */

        for(int k = 0; k < nr_states; k++)
            fluxes_i[nr_states * spid + k] += pifx[k];
        
    } /* loop over the particles in cell_j. */
        
    TIMER_TOC(tid_pair)
    
}

/**
 * @brief Compute the pairwise interactions for the given pair on a CUDA device.
 *
 * @param icid Array of parts in the first cell.
 * @param count_i Number of parts in the first cell.
 * @param icjd Array of parts in the second cell.
 * @param count_j Number of parts in the second cell.
 * @param pshift A pointer to an array of three floating point values containing
 *      the vector separating the centers of @c cell_i and @c cell_j.
 * @param cid Part buffer in local memory.
 * @param cjd Part buffer in local memory.
 *
 * @sa #runner_dopair.
 */
__device__ void runner_dopair_state_right_cuda(
    int ind_i, float *states_i, int count_i, 
    int ind_j, float *states_j, int count_j, 
    float4* parts_pos_i, int4* parts_datai_i, 
    float4* parts_pos_j, int4* parts_datai_j, 
    float *fluxes_i, 
    unsigned int *sort_i, unsigned int *sort_j, 
    float *shift, unsigned int dshift, unsigned int nr_states
) {
    
    TIMER_TIC
    
    for(int i = threadIdx.x ; i < count_i ;  i += blockDim.x) {

        unsigned int di = (sort_i[i]&0xffff);
        /* Get a direct pointer on the pjdth part in cell_j. */
        int spid = sort_i[i] >> 16;
        float4 pix = parts_pos_i[spid];
        pix.x += shift[0]; pix.y += shift[1]; pix.z += shift[2];
        int typeIdi = parts_datai_i[spid].y;
        int pioff = typeIdi * cuda_maxtype;

        float pifx[TF_SIMD_SIZE];
        memset(pifx, 0.f, nr_states * sizeof(float));
        float *pis = &states_i[nr_states * spid];

        /* Loop over the particles in cell_j. */
        for(int k = 0 ; k < count_j && di + dshift <= cuda_dmaxdist + (sort_j[k]&0xffff) ; k++) {
                 
            /* Get a handle on the wrapped particle pid in cell_i. */

            int spjd = sort_j[k] >> 16;

            /* Compute the radius between pi and pj. */
            float4 pjx = parts_pos_j[spjd];
            float r2 = 0.0f, dx;
            dx = pix.x - pjx.x; r2 += dx * dx;
            dx = pix.y - pjx.y; r2 += dx * dx;
            dx = pix.z - pjx.z; r2 += dx * dx;

            if(r2 >= cuda_cutoff2) {
                continue;
            }

            int typeIdj = parts_datai_j[spjd].y;
            int fxind = cuda_fxind[pioff + typeIdj];
            if(fxind != 0) {
                flux_eval_ex_cuda(cuda_fluxes[fxind], sqrtf(r2), pis, &states_j[nr_states * spjd], typeIdi, typeIdj, pifx);
            }

        } /* loop over parts in cell_i. */

        for(int k = 0; k < nr_states; k++)
            fluxes_i[nr_states * spid + k] += pifx[k];
        
    } /* loop over the particles in cell_j. */
        
    TIMER_TOC(tid_pair)
    
}

/**
 * @brief Compute the self interactions for the given cell on a CUDA device.
 *
 * @param iparts Array of parts in this cell.
 * @param count Number of parts in the cell.
 * @param parts Part buffer in local memory.
 *
 * @sa #runner_dopair.
 */
__device__ void runner_doself_cuda(
    int ind, int count, 
    float4* parts_pos, 
    int4* parts_datai, 
    float *forces, float *epot_global
) {
    float epot = 0.0f;
    
    TIMER_TIC

    /* Loop over the particles in the cell, frame-wise. */
    for(int i = threadIdx.x ; i < count ;  i += blockDim.x) {
    
        /* Get a direct pointer on the pjdth part in cell_j. */
        int pidi = ind + i;
        float4 pix = parts_pos[i];
        float pif[] = {0.0f, 0.0f, 0.0f, 0.0f};
        int4 pdatai_i = parts_datai[i];
        int pioff = pdatai_i.y * cuda_maxtype;
        bool iscluster_maybe = pdatai_i.z & PARTICLE_BOUND;
        int clusterIdi = pdatai_i.w;

        /* Loop over the particles in cell_i. */
        for(int k = 0 ; k < count ; k++) {
        	if(i != k) {

                /* Compute the radius between pi and pj. */
                float4 pjx = parts_pos[k];
                float3 dx{pix.x - pjx.x, pix.y - pjx.y, pix.z - pjx.z};
                float r2 = dx.x * dx.x + dx.y * dx.y + dx.z * dx.z;

                if(r2 < cuda_cutoff2) {

                    float number_density;

                    w_cubic_spline_cuda_nr(r2, cuda_cutoff, &number_density);

                    pif[3] += number_density;

                    int pind, nr_pots, nr_dpds;
                    int4 pdatai_j = parts_datai[k];
                    int pjoff = ENGINE_CUDA_PIND_WIDTH * (pioff + pdatai_j.y);
                    bool iscluster = iscluster_maybe && pdatai_j.z & PARTICLE_BOUND && pdatai_j.w == clusterIdi;

                    if(iscluster) {
                        pind    = cuda_pind_cluster[pjoff    ];
                        nr_pots = cuda_pind_cluster[pjoff + 1];
                        nr_dpds = cuda_pind_cluster[pjoff + 2];
                    }
                    else {
                        pind    = cuda_pind[pjoff    ];
                        nr_pots = cuda_pind[pjoff + 1];
                        nr_dpds = cuda_pind[pjoff + 2];
                    }
                    if(pind != 0) {

                        float ee = 0.0f;
                        int pidj = ind + k;

                        /* Interact particles pi and pj. */
                        if(iscluster) 
                            potential_eval_super_ex_cuda<true>(pind, nr_pots, nr_dpds, pix.w, pjx.w, pidi, pidj, dx, r2, &ee, pif);
                        else 
                            potential_eval_super_ex_cuda<false>(pind, nr_pots, nr_dpds, pix.w, pjx.w, pidi, pidj, dx, r2, &ee, pif);

                        /* Store the interaction force and energy. */
                        epot += ee;
                    }
                }

			}
        } /* loop over parts in cell_i. */

        /* Update the force on pj. */
        #pragma unroll
        for(int k = 0 ; k < 4 ; k++)
            forces[4*i + k] += pif[k];

    } /* loop over the particles in cell_j. */

    /* Store the potential energy. */
    *epot_global += epot;
        
    TIMER_TOC(tid_self)
    
}

/**
 * @brief Compute the self interactions for the given cell on a CUDA device.
 *
 * @param iparts Array of parts in this cell.
 * @param count Number of parts in the cell.
 * @param parts Part buffer in local memory.
 *
 * @sa #runner_dopair.
 */
__device__ void runner_doself_cuda(
    int indi, int indj, 
    int counti, int countj, 
    float4* parts_pos_i, int4* parts_datai_i, 
    float4* parts_pos_j, int4* parts_datai_j, 
    float *forces_i, float *epot_global
) {
    float epot = 0.0f;
    
    TIMER_TIC

    /* Loop over the particles in the cell, frame-wise. */
    for(int i = threadIdx.x ; i < counti ;  i += blockDim.x) {
    
        /* Get a direct pointer on the pjdth part in cell_j. */
        int pidi = indi + i;
        float4 pix = parts_pos_i[i];
        float pif[] = {0.0f, 0.0f, 0.0f, 0.0f};
        int4 pdatai_i = parts_datai_i[i];
        int pioff = pdatai_i.y * cuda_maxtype;
        bool iscluster_maybe = pdatai_i.z & PARTICLE_BOUND;
        int clusterIdi = pdatai_i.w;

        /* Loop over the particles in cell_i. */
        for(int k = 0 ; k < countj ; k++) {

            int pidj = indj + k;

        	if(pidi != pidj) {

                /* Compute the radius between pi and pj. */
                float4 pjx = parts_pos_j[k];
                float3 dx{pix.x - pjx.x, pix.y - pjx.y, pix.z - pjx.z};
                float r2 = dx.x * dx.x + dx.y * dx.y + dx.z * dx.z;

                if(r2 < cuda_cutoff2) {

                    float number_density;

                    w_cubic_spline_cuda_nr(r2, cuda_cutoff, &number_density);

                    pif[3] += number_density;

                    int pind, nr_pots, nr_dpds;
                    int4 pdatai_j = parts_datai_j[k];
                    int pjoff = ENGINE_CUDA_PIND_WIDTH * (pioff + pdatai_j.y);
                    bool iscluster = iscluster_maybe && pdatai_j.z & PARTICLE_BOUND && pdatai_j.w == clusterIdi;

                    if(iscluster) {
                        pind    = cuda_pind_cluster[pjoff    ];
                        nr_pots = cuda_pind_cluster[pjoff + 1];
                        nr_dpds = cuda_pind_cluster[pjoff + 2];
                    }
                    else {
                        pind    = cuda_pind[pjoff    ];
                        nr_pots = cuda_pind[pjoff + 1];
                        nr_dpds = cuda_pind[pjoff + 2];
                    }
                    if(pind != 0) {

                        float ee = 0.0f;
                        
                        /* Interact particles pi and pj. */
                        if(iscluster) 
                            potential_eval_super_ex_cuda<true>(pind, nr_pots, nr_dpds, pix.w, pjx.w, pidi, pidj, dx, r2, &ee, pif);
                        else 
                            potential_eval_super_ex_cuda<false>(pind, nr_pots, nr_dpds, pix.w, pjx.w, pidi, pidj, dx, r2, &ee, pif);

                        /* Store the interaction force and energy. */
                        epot += ee;
                    }
                }

			}
        } /* loop over parts in cell_i. */

        /* Update the force on pj. */
        #pragma unroll
        for(int k = 0 ; k < 4 ; k++)
            forces_i[4*i + k] += pif[k];

    } /* loop over the particles in cell_j. */

    /* Store the potential energy. */
    *epot_global += epot;
        
    TIMER_TOC(tid_self)
    
}

/**
 * @brief Compute the self interactions for the given cell on a CUDA device.
 *
 * @param iparts Array of parts in this cell.
 * @param count Number of parts in the cell.
 * @param parts Part buffer in local memory.
 *
 * @sa #runner_dopair.
 */
__device__ void runner_doboundary_self_cuda(
    int ind, int count, 
    int cell_id, unsigned int cell_flags, float3 cdims, 
    float4* parts_pos, 
    int4* parts_datai, 
    float *forces, float *epot_global
) {
    float epot = 0.0f;
    
    TIMER_TIC

    /* Loop over the particles in the cell, frame-wise. */
    for(int i = threadIdx.x ; i < count ;  i += blockDim.x) {
    
        float pjf[] = {0.0f, 0.0f, 0.0f, 0.0f};

        boundary_eval_cuda(parts_pos[i], ind + i, parts_datai[i].y, cdims, cell_flags, pjf, &epot);

        /* Update the force on pj. */
        for(int k = 0 ; k < 4 ; k++)
        	forces[4*i + k] += pjf[k];

    } /* loop over the particles in cell_j. */

    /* Store the potential energy. */
    *epot_global += epot;
        
    TIMER_TOC(tid_self)
    
}

/**
 * @brief Compute the self interactions for the given cell on a CUDA device.
 *
 * @param iparts Array of parts in this cell.
 * @param count Number of parts in the cell.
 * @param parts Part buffer in local memory.
 *
 * @sa #runner_dopair.
 */
__device__ void runner_doself_state_cuda(
    int ind, float *states, int count, 
    float4* parts_pos, int4* parts_datai, 
    float *fluxes, unsigned int nr_states
) {
    
    TIMER_TIC

    /* Loop over the particles in the cell, frame-wise. */
    for(int i = threadIdx.x ; i < count ;  i += blockDim.x) {
    
        /* Get a direct pointer on the pjdth part in cell_j. */
        int typeIdj = parts_datai[i].y;
        int pjoff = typeIdj * cuda_maxtype;
        float4 pjx = parts_pos[i];

        float pjfx[TF_SIMD_SIZE];
        memset(pjfx, 0.f, nr_states * sizeof(float));
        float *pjs = &states[nr_states * i];
        
        /* Loop over the particles in cell_i. */
        for(int k = 0 ; k < count ; k++) {
        	if(i != k) {
                /* Compute the radius between pi and pj. */
                float4 pix = parts_pos[k];
                float r2 = 0.0f, dx;
                dx = pix.x - pjx.x; r2 += dx * dx;
                dx = pix.y - pjx.y; r2 += dx * dx;
                dx = pix.z - pjx.z; r2 += dx * dx;

                if(r2 >= cuda_cutoff2) {
                    continue;
                }

                int typeIdi = parts_datai[k].y;
                int fxind = cuda_fxind[pjoff + typeIdi];
                if(fxind != 0) {
                    flux_eval_ex_cuda(cuda_fluxes[fxind], sqrtf(r2), pjs, &states[nr_states * k], typeIdj, typeIdi, pjfx);
                }

			}
        } /* loop over parts in cell_i. */

        for(int k = 0; k < nr_states; k++)
            fluxes[nr_states * i + k] += pjfx[k];

    } /* loop over the particles in cell_j. */
        
    TIMER_TOC(tid_self)
    
}

/**
 * @brief Our very own memset for the particle forces as cudaMemsetAsync requires
 *        a device switch when using streams on different devices.
 *
 */ 
__global__ void cuda_memset_float(float *data, float val, int N) {

    int k, tid = threadIdx.x + blockIdx.x * blockDim.x;
    int stride = gridDim.x * blockDim.x;
    
    for(k = tid ; k < N ; k += stride)
        data[k] = val;

}

__global__ void runner_run_cuda_do_sort_kernel(int* counts, int* ind) {
    extern __shared__ unsigned int sort_s[];

    for(int cid = blockIdx.x; cid < cuda_nr_cells; cid += gridDim.x) {
        if(cuda_cflags[cid] != 0) {
            int indc = ind[cid];
            int countc = counts[cid];
            float4* part_pos = &cuda_parts_pos[indc];
            for(int sid = 0; sid < 13; sid++) {
                runner_dosort_cuda(part_pos, countc, sort_s, sid);
                __syncthreads();
                cuda_memcpy(&cuda_sortlists[13 * indc + sid * countc], sort_s, sizeof(unsigned int) * countc);
                __syncthreads();
            }
        }
    }
}

template<bool is_stateful> 
__global__ void runner_run_cuda_do_self_kernel(
    float* forces, float* fluxes, unsigned int nr_states, 
    int* counts, int* ind
) {
    float epot;

    for(int cid = blockIdx.x; cid < cuda_nr_cells; cid += gridDim.x) {

        int indi = ind[cid];
        int counti = counts[cid];
        float3 cdims = cuda_cdims[cid];

        float4* parts_pos = &cuda_parts_pos[indi];
        int4* parts_datai = &cuda_parts_datai[indi];
        
        /* Put a finger on the forces. */
        float *forces_i = &forces[4*indi];

        unsigned int cell_flags = cuda_cflags[cid];
        bool boundary = cell_flags & cell_active_any;

        if(boundary) {
            runner_doboundary_self_cuda(
                indi, counti, cid, 
                cell_flags, cdims, 
                parts_pos, parts_datai, 
                forces_i, &epot
            );

            __syncthreads();
        }
            
        /* Compute the cell self interactions. */
        runner_doself_cuda(
            indi, counti, 
            parts_pos, 
            parts_datai, 
            forces_i, &epot
        );

        if(is_stateful) {
            __syncthreads();
            
            float *fluxes_i = &fluxes[nr_states * indi];
            float *states_j = &cuda_part_states[nr_states * indi];
            runner_doself_state_cuda(indi, states_j, counti, parts_pos, parts_datai, fluxes_i, nr_states);
        }

        __syncthreads();
    }

    atomicAdd(&cuda_epot, epot * 0.5f);
}

__global__ void runner_run_cuda_do_self_fluxonly_kernel(float* fluxes, unsigned int nr_states, int* counts, int* ind) {

    for(int cid = blockIdx.x; cid < cuda_nr_cells; cid += gridDim.x) {

        int indi = ind[cid];
        int counti = counts[cid];

        float4* parts_pos = &cuda_parts_pos[indi];
        int4* parts_datai = &cuda_parts_datai[indi];
        
        float *fluxes_i = &fluxes[nr_states * indi];
        float *states_j = &cuda_part_states[nr_states * indi];
        runner_doself_state_cuda(indi, states_j, counti, parts_pos, parts_datai, fluxes_i, nr_states);

        __syncthreads();
    }

}

template<bool is_stateful> 
__global__ void runner_run_cuda_do_pair_left_kernel(
    float* forces, float* fluxes, unsigned int nr_states, 
    int* counts, int* ind, 
    unsigned int cuda_nrparts
) { 
    float epot = 0.0f;

    __shared__ float shiftn[39];
    __shared__ float shift[3];
    __shared__ unsigned int dshift;
    extern __shared__ unsigned int sort_arrs[];
    unsigned int *sort_i = (unsigned int*)&sort_arrs[0];
    unsigned int *sort_j = (unsigned int*)&sort_arrs[cuda_nrparts];

    // Copy shifts to shared memory
    for(int i = threadIdx.x; i < 39; i += blockDim.x) shiftn[i] = cuda_shiftn[i];
    __syncthreads();

    for(int cid = blockIdx.x; cid < cuda_nr_cells; cid += gridDim.x) {
        int cellpair_count = cuda_cellpair_count_left[cid];
        int cellpair_ind = cuda_cellpair_ind_left[cid];
        int2* cellpair_list = &cuda_cellpair_list_left[cellpair_ind];
        for(int j = 0; j < cellpair_count; j++) {
            int2 cellpair = cellpair_list[j];
            int cjd = cellpair.x;
            int cflags = cellpair.y;

            /* Get the shift and dshift vector for this pair. */
            if(threadIdx.x == 0) {
                #pragma unroll
                for(int k = 0 ; k < 3 ; k++) {
                    shift[k] = cuda_corig[3*cjd + k] - cuda_corig[3*cid + k];
                    if(2*shift[k] > cuda_dim[k])
                        shift[k] -= cuda_dim[k];
                    else if(2*shift[k] < -cuda_dim[k])
                        shift[k] += cuda_dim[k];
                }
                dshift = cuda_dscale *(
                    shift[0]*shiftn[3 * cflags    ] +
                    shift[1]*shiftn[3 * cflags + 1] +
                    shift[2]*shiftn[3 * cflags + 2]
                );
            }
            
            /* Load the sorted indices. */

            int indi = ind[cid];
            int indj = ind[cjd];
            int counti = counts[cid];
            int countj = counts[cjd];

            cuda_memcpy(sort_i, &cuda_sortlists[13*indi + counti*cflags], sizeof(int)*counti);
            cuda_memcpy(sort_j, &cuda_sortlists[13*indj + countj*cflags], sizeof(int)*countj);
            __syncthreads();

            float4* parts_pos_i = &cuda_parts_pos[indi];
            int4* parts_datai_i = &cuda_parts_datai[indi];
            
            float4* parts_pos_j = &cuda_parts_pos[indj];
            int4* parts_datai_j = &cuda_parts_datai[indj];

            float *forces_i = &forces[4*indi];

            runner_dopair_left_cuda(
                indi, counti, 
                indj, countj, 
                parts_pos_i, parts_datai_i, 
                parts_pos_j, parts_datai_j, 
                forces_i, 
                sort_i, sort_j, 
                shift, dshift, &epot
            );

            if(is_stateful) {

                __syncthreads();
                
                float *states_i = &cuda_part_states[nr_states * indi];
                float *states_j = &cuda_part_states[nr_states * indj];
                float *fluxes_i = &fluxes[nr_states * indi];
                
                /*Set to left interaction*/
                /* Compute the cell pair interactions. */
                runner_dopair_state_left_cuda(
                    indi, states_i, counti,
                    indj, states_j, countj,
                    parts_pos_i, parts_datai_i, 
                    parts_pos_j, parts_datai_j, 
                    fluxes_i, 
                    sort_i, sort_j,
                    shift, dshift, nr_states
                );
            }

            __syncthreads();
        }
    }

    atomicAdd(&cuda_epot, epot * 0.5f);
}

__global__ void runner_run_cuda_do_pair_left_fluxonly_kernel(
    float* fluxes, unsigned int nr_states, 
    int* counts, int* ind, 
    unsigned int cuda_nrparts
) { 

    __shared__ float shiftn[39];
    __shared__ float shift[3];
    __shared__ unsigned int dshift;
    extern __shared__ unsigned int sort_arrs[];
    unsigned int *sort_i = (unsigned int*)&sort_arrs[0];
    unsigned int *sort_j = (unsigned int*)&sort_arrs[cuda_nrparts];

    // Copy shifts to shared memory
    for(int i = threadIdx.x; i < 39; i += blockDim.x) shiftn[i] = cuda_shiftn[i];
    __syncthreads();

    for(int cid = blockIdx.x; cid < cuda_nr_cells; cid += gridDim.x) {
        int cellpair_count = cuda_cellpair_count_left[cid];
        int cellpair_ind = cuda_cellpair_ind_left[cid];
        int2* cellpair_list = &cuda_cellpair_list_left[cellpair_ind];
        for(int j = 0; j < cellpair_count; j++) {
            int2 cellpair = cellpair_list[j];
            int cjd = cellpair.x;
            int cflags = cellpair.y;

            /* Get the shift and dshift vector for this pair. */
            if(threadIdx.x == 0) {
                #pragma unroll
                for(int k = 0 ; k < 3 ; k++) {
                    shift[k] = cuda_corig[3*cjd + k] - cuda_corig[3*cid + k];
                    if(2*shift[k] > cuda_dim[k])
                        shift[k] -= cuda_dim[k];
                    else if(2*shift[k] < -cuda_dim[k])
                        shift[k] += cuda_dim[k];
                }
                dshift = cuda_dscale *(
                    shift[0]*shiftn[3 * cflags    ] +
                    shift[1]*shiftn[3 * cflags + 1] +
                    shift[2]*shiftn[3 * cflags + 2]
                );
            }
            
            /* Load the sorted indices. */

            int indi = ind[cid];
            int indj = ind[cjd];
            int counti = counts[cid];
            int countj = counts[cjd];

            cuda_memcpy(sort_i, &cuda_sortlists[13*indi + counti*cflags], sizeof(int)*counti);
            cuda_memcpy(sort_j, &cuda_sortlists[13*indj + countj*cflags], sizeof(int)*countj);
            __syncthreads();

            float4* parts_pos_i = &cuda_parts_pos[indi];
            int4* parts_datai_i = &cuda_parts_datai[indi];
            
            float4* parts_pos_j = &cuda_parts_pos[indj];
            int4* parts_datai_j = &cuda_parts_datai[indj];

            float *states_i = &cuda_part_states[nr_states * indi];
            float *states_j = &cuda_part_states[nr_states * indj];
            float *fluxes_i = &fluxes[nr_states * indi];
            
            /*Set to left interaction*/
            /* Compute the cell pair interactions. */
            runner_dopair_state_left_cuda(
                indi, states_i, counti,
                indj, states_j, countj,
                parts_pos_i, parts_datai_i, 
                parts_pos_j, parts_datai_j, 
                fluxes_i, 
                sort_i, sort_j,
                shift, dshift, nr_states
            );

            __syncthreads();
        }
    }

}

template<bool is_stateful> 
__global__ void runner_run_cuda_do_pair_right_kernel(
    float* forces, float* fluxes, unsigned int nr_states, 
    int* counts, int* ind, 
    unsigned int cuda_nrparts
) { 
    float epot = 0.0f;

    __shared__ float shiftn[39];
    __shared__ float shift[3];
    __shared__ unsigned int dshift;
    extern __shared__ unsigned int sort_arrs[];
    unsigned int *sort_i = (unsigned int*)&sort_arrs[0];
    unsigned int *sort_j = (unsigned int*)&sort_arrs[cuda_nrparts];

    // Copy shifts to shared memory
    for(int i = threadIdx.x; i < 39; i += blockDim.x) shiftn[i] = cuda_shiftn[i];
    __syncthreads();

    for(int cjd = blockIdx.x; cjd < cuda_nr_cells; cjd += gridDim.x) {
        int cellpair_count = cuda_cellpair_count_right[cjd];
        int cellpair_ind = cuda_cellpair_ind_right[cjd];
        int2* cellpair_list = &cuda_cellpair_list_right[cellpair_ind];
        for(int j = 0; j < cellpair_count; j++) {
            int2 cellpair = cellpair_list[j];
            int cid = cellpair.x;
            int cflags = cellpair.y;

            /* Get the shift and dshift vector for this pair. */
            if(threadIdx.x == 0) {
                #pragma unroll
                for(int k = 0 ; k < 3 ; k++) {
                    shift[k] = cuda_corig[3*cjd + k] - cuda_corig[3*cid + k];
                    if(2*shift[k] > cuda_dim[k])
                        shift[k] -= cuda_dim[k];
                    else if(2*shift[k] < -cuda_dim[k])
                        shift[k] += cuda_dim[k];
                }
                dshift = cuda_dscale * (
                    shift[0]*shiftn[3 * cflags    ] +
                    shift[1]*shiftn[3 * cflags + 1] +
                    shift[2]*shiftn[3 * cflags + 2]
                );
            }
            
            /* Load the sorted indices. */

            int indi = ind[cid];
            int indj = ind[cjd];
            int counti = counts[cid];
            int countj = counts[cjd];

            cuda_memcpy(sort_i, &cuda_sortlists[13*indi + counti*cflags], sizeof(int)*counti);
            cuda_memcpy(sort_j, &cuda_sortlists[13*indj + countj*cflags], sizeof(int)*countj);
            __syncthreads();
            
            float4* parts_pos_i = &cuda_parts_pos[indi];
            int4* parts_datai_i = &cuda_parts_datai[indi];
            
            float4* parts_pos_j = &cuda_parts_pos[indj];
            int4* parts_datai_j = &cuda_parts_datai[indj];
            
            float *forces_j = &forces[4*indj];

            runner_dopair_right_cuda(
                indj, countj, 
                indi, counti, 
                parts_pos_j, parts_datai_j, 
                parts_pos_i, parts_datai_i, 
                forces_j, 
                sort_j, sort_i, 
                shift, dshift, &epot
            );

            if(is_stateful) {

                __syncthreads();
                
                float *states_i = &cuda_part_states[nr_states * indi];
                float *states_j = &cuda_part_states[nr_states * indj];
                float *fluxes_j = &fluxes[nr_states * indj];

                /*Set to right interaction*/
                /* Compute the cell pair interactions. */
                runner_dopair_state_right_cuda(
                    indj, states_j, countj,
                    indi, states_i, counti,
                    parts_pos_j, parts_datai_j, 
                    parts_pos_i, parts_datai_i, 
                    fluxes_j, 
                    sort_j, sort_i,
                    shift, dshift, nr_states
                );
            }

            __syncthreads();
        }
    }

    atomicAdd(&cuda_epot, epot * 0.5f);
}

__global__ void runner_run_cuda_do_pair_right_fluxonly_kernel(
    float* fluxes, unsigned int nr_states, 
    int* counts, int* ind, 
    unsigned int cuda_nrparts
) { 

    __shared__ float shiftn[39];
    __shared__ float shift[3];
    __shared__ unsigned int dshift;
    extern __shared__ unsigned int sort_arrs[];
    unsigned int *sort_i = (unsigned int*)&sort_arrs[0];
    unsigned int *sort_j = (unsigned int*)&sort_arrs[cuda_nrparts];

    // Copy shifts to shared memory
    for(int i = threadIdx.x; i < 39; i += blockDim.x) shiftn[i] = cuda_shiftn[i];
    __syncthreads();

    for(int cjd = blockIdx.x; cjd < cuda_nr_cells; cjd += gridDim.x) {
        int cellpair_count = cuda_cellpair_count_right[cjd];
        int cellpair_ind = cuda_cellpair_ind_right[cjd];
        int2* cellpair_list = &cuda_cellpair_list_right[cellpair_ind];
        for(int j = 0; j < cellpair_count; j++) {
            int2 cellpair = cellpair_list[j];
            int cid = cellpair.x;
            int cflags = cellpair.y;

            /* Get the shift and dshift vector for this pair. */
            if(threadIdx.x == 0) {
                #pragma unroll
                for(int k = 0 ; k < 3 ; k++) {
                    shift[k] = cuda_corig[3*cjd + k] - cuda_corig[3*cid + k];
                    if(2*shift[k] > cuda_dim[k])
                        shift[k] -= cuda_dim[k];
                    else if(2*shift[k] < -cuda_dim[k])
                        shift[k] += cuda_dim[k];
                }
                dshift = cuda_dscale * (
                    shift[0]*shiftn[3 * cflags    ] +
                    shift[1]*shiftn[3 * cflags + 1] +
                    shift[2]*shiftn[3 * cflags + 2]
                );
            }
            
            /* Load the sorted indices. */

            int indi = ind[cid];
            int indj = ind[cjd];
            int counti = counts[cid];
            int countj = counts[cjd];

            cuda_memcpy(sort_i, &cuda_sortlists[13*indi + counti*cflags], sizeof(int)*counti);
            cuda_memcpy(sort_j, &cuda_sortlists[13*indj + countj*cflags], sizeof(int)*countj);
            __syncthreads();
            
            float4* parts_pos_i = &cuda_parts_pos[indi];
            int4* parts_datai_i = &cuda_parts_datai[indi];
            
            float4* parts_pos_j = &cuda_parts_pos[indj];
            int4* parts_datai_j = &cuda_parts_datai[indj];
            
            float *states_i = &cuda_part_states[nr_states * indi];
            float *states_j = &cuda_part_states[nr_states * indj];
            float *fluxes_j = &fluxes[nr_states * indj];

            /*Set to right interaction*/
            /* Compute the cell pair interactions. */
            runner_dopair_state_right_cuda(
                indj, states_j, countj,
                indi, states_i, counti,
                parts_pos_j, parts_datai_j, 
                parts_pos_i, parts_datai_i, 
                fluxes_j, 
                sort_j, sort_i,
                shift, dshift, nr_states
            );

            __syncthreads();
        }
    }

}

__global__ void runner_run_cuda_integrate_state_kernel(float* fluxes, int* species_flags, unsigned int nr_fluxes, float dt_flux) {
    int stride = blockDim.x * gridDim.x;

    for(int i = blockDim.x * blockIdx.x + threadIdx.x; i < nr_fluxes; i += stride) {
        float state = cuda_part_states[i];
        float flux = fluxes[i] * (1.0 - float(species_flags[i] & state::SpeciesFlags::SPECIES_KONSTANT));
        cuda_part_states[i] = state + dt_flux * flux;
        fluxes[i] = 0.0;
    }
}

extern "C" HRESULT cuda::engine_nonbond_cuda(struct engine *e) {

    int k, did, maxcount = 0;
    cudaStream_t stream;
    cudaEvent_t tic, toc_load, toc_run, toc_unload;
    float ms_load, ms_run, ms_unload;
    float4* parts_pos_cuda = (float4*)e->parts_pos_cuda_local;
    float3* parts_vel_cuda = (float3*)e->parts_vel_cuda_local;
    int4* parts_datai_cuda = (int4*)e->parts_datai_cuda_local;
    float *part_states_cuda = (float *)e->part_states_cuda_local;
    int *part_species_flags_cuda = e->part_species_flags_cuda_local;
    struct space *s = &e->s;
    FPTYPE maxdist = s->cutoff + 2*s->maxdx;
    int *counts = e->counts_cuda_local[ 0 ], *inds = e->ind_cuda_local[ 0 ];
    float *forces_cuda[ engine_maxgpu ], *fluxes_next_cuda[engine_maxgpu], epot[ engine_maxgpu ], *part_states_next_cuda[engine_maxgpu];
    float epot_init = 0.f;
    unsigned int nr_states = e->nr_fluxes_cuda - 1;
    #ifdef TIMERS
        float timers[ tid_count ];
        double icpms = 1000.0 / 1.4e9; 
    #endif
    
    /* Create the events. */
    if(cudaSetDevice(e->devices[e->nr_devices-1]) ||
         cudaEventCreate(&tic) != cudaSuccess ||
         cudaEventCreate(&toc_load) != cudaSuccess ||
         cudaEventCreate(&toc_run) != cudaSuccess ||
         cudaEventCreate(&toc_unload) != cudaSuccess)
        return cuda_error();
    
    /* Start the clock on the first stream. */
    cuda_safe_call(cudaEventRecord(tic, (cudaStream_t)e->streams[e->nr_devices-1]));
    
    /* Re-set timers */
    #ifdef TIMERS
        for(int k = 0 ; k < tid_count ; k++)
            timers[k] = 0.0f;
        for(did = 0 ; did < e->nr_devices ; did++)
            cuda_safe_call(cudaMemcpyToSymbolAsync(cuda_timers, timers, sizeof(float) * tid_count, 0, cudaMemcpyHostToDevice, (cudaStream_t)e->streams[did]));
    #endif

    std::vector<TissueForge::Particle*> cell_parts;
    cell_parts.reserve(s->nr_cells);
    for(int k = 0; k < s->nr_cells; k++) {
        cell_parts.push_back(s->cells[k].parts);
    }
    
    /* Loop over the devices and call the different kernels on each stream. */
    for(did = 0 ; did < e->nr_devices ; did++) {
    
        /* Set the device ID. */
        cuda_safe_call(cudaSetDevice(e->devices[did]));

        /* Get the stream. */
        stream = (cudaStream_t)e->streams[did];

        cuda_safe_call(cudaMemcpyToSymbolAsync(cuda_epot, &epot_init, sizeof(float), 0, cudaMemcpyHostToDevice, stream));
        
        /* Load the particle data onto the device. */
        
        counts = e->counts_cuda_local[ did ];
        inds = e->ind_cuda_local[ did ];
        /* Clear the counts array. */
        bzero(counts, sizeof(int) * s->nr_cells);

        /* Load the counts. */
        for(maxcount = 0, k = 0; k < e->cells_cuda_nr[did] ; k++)
            if((counts[e->cells_cuda_local[did][k]] = s->cells[e->cells_cuda_local[did][k]].count) > maxcount)
                maxcount = counts[ e->cells_cuda_local[did][k]];

        /* Raise maxcount to the next multiple of 32. */
        maxcount =(maxcount + (cuda_frame - 1)) & ~(cuda_frame - 1);

        /* Compute the indices. */
        inds[0] = 0;
        for(k = 1 ; k < e->cells_cuda_nr[did] ; k++)
            inds[k] = inds[k-1] + counts[k-1];

        auto _cells_cuda_local = e->cells_cuda_local[did];

        if(nr_states > 0) {
            if(e->nr_fluxsteps > 1) {
                auto func = [&](int k) -> void {

                    /* Get the cell id. */
                    auto cid = _cells_cuda_local[k];

                    /* Copy the particle data to the device. */
                    auto buff_parts_pos_cuda = &parts_pos_cuda[inds[cid]];
                    auto buff_parts_vel_cuda = &parts_vel_cuda[inds[cid]];
                    auto buff_parts_datai_cuda = &parts_datai_cuda[inds[cid]];
                    auto buff_part_states = &part_states_cuda[nr_states * inds[cid]];
                    auto buff_part_species_flags = &part_species_flags_cuda[nr_states * inds[cid]];
                    for(int pid = 0 ; pid < counts[cid] ; pid++) {
                        TissueForge::Particle *part = &cell_parts[cid][pid];
                        buff_parts_pos_cuda[pid] = {part->x[0], part->x[1], part->x[2], part->radius};
                        buff_parts_vel_cuda[pid] = {part->v[0], part->v[1], part->v[2]};
                        buff_parts_datai_cuda[pid] = {part->id, part->typeId, part->flags, part->clusterId};
                        for(int ks = 0; ks < nr_states; ks++) {
                            buff_part_states[nr_states * pid + ks] = part->state_vector->fvec[ks];
                            buff_part_species_flags[nr_states * pid + ks] = part->state_vector->species_flags[ks];
                        }
                    }

                };

                parallel_for(e->cells_cuda_nr[did], func);
            } 
            else {
                auto func = [&](int k) -> void {

                    /* Get the cell id. */
                    auto cid = _cells_cuda_local[k];

                    /* Copy the particle data to the device. */
                    auto buff_parts_pos_cuda = &parts_pos_cuda[inds[cid]];
                    auto buff_parts_vel_cuda = &parts_vel_cuda[inds[cid]];
                    auto buff_parts_datai_cuda = &parts_datai_cuda[inds[cid]];
                    auto buff_part_states = &part_states_cuda[nr_states * inds[cid]];
                    for(int pid = 0 ; pid < counts[cid] ; pid++) {
                        TissueForge::Particle *part = &cell_parts[cid][pid];
                        buff_parts_pos_cuda[pid] = {part->x[0], part->x[1], part->x[2], part->radius};
                        buff_parts_vel_cuda[pid] = {part->v[0], part->v[1], part->v[2]};
                        buff_parts_datai_cuda[pid] = {part->id, part->typeId, part->flags, part->clusterId};
                        for(int ks = 0; ks < nr_states; ks++) 
                            buff_part_states[nr_states * pid + ks] = part->state_vector->fvec[ks];
                    }

                };

                parallel_for(e->cells_cuda_nr[did], func);
            }
        } 
        else {
            auto func = [&](int k) -> void {

                /* Get the cell id. */
                auto cid = _cells_cuda_local[k];

                /* Copy the particle data to the device. */
                auto buff_parts_pos_cuda = &parts_pos_cuda[inds[cid]];
                auto buff_parts_vel_cuda = &parts_vel_cuda[inds[cid]];
                auto buff_parts_datai_cuda = &parts_datai_cuda[inds[cid]];
                for(int pid = 0 ; pid < counts[cid] ; pid++) {
                    TissueForge::Particle* part = &cell_parts[cid][pid];
                    buff_parts_pos_cuda[pid] = {part->x[0], part->x[1], part->x[2], part->radius};
                    buff_parts_vel_cuda[pid] = {part->v[0], part->v[1], part->v[2]};
                    buff_parts_datai_cuda[pid] = {part->id, part->typeId, part->flags, part->clusterId};
                }

            };

            parallel_for(e->cells_cuda_nr[did], func);
        }

	    /* Start by setting the maxdist on the device. */
        cuda_safe_call(cudaMemcpyToSymbolAsync(cuda_maxdist, &maxdist, sizeof(float), 0, cudaMemcpyHostToDevice, stream));

        /* Copy the counts onto the device. */
        cuda_safe_call(cudaMemcpyAsync(e->counts_cuda[did], counts, sizeof(int) * s->nr_cells, cudaMemcpyHostToDevice, stream));

        /* Copy the inds onto the device. */
        cuda_safe_call(cudaMemcpyAsync(e->ind_cuda[did], inds, sizeof(int) * s->nr_cells, cudaMemcpyHostToDevice, stream));

        /* Bind the particle positions. */
        cuda_safe_call(cudaMemcpyAsync(e->parts_pos_cuda[did], parts_pos_cuda, sizeof(float4) * s->nr_parts, cudaMemcpyHostToDevice, stream));
        cuda_safe_call(cudaMemcpyAsync(e->parts_vel_cuda[did], parts_vel_cuda, sizeof(float3) * s->nr_parts, cudaMemcpyHostToDevice, stream));
        cuda_safe_call(cudaMemcpyAsync(e->parts_datai_cuda[did], parts_datai_cuda, sizeof(int4) * s->nr_parts, cudaMemcpyHostToDevice, stream));

        if(nr_states > 0) {
            /* Bind the particle states. */
            cuda_safe_call(cudaMemcpyAsync(e->part_states_cuda[did], part_states_cuda, sizeof(float) * s->nr_parts * nr_states, cudaMemcpyHostToDevice, stream));
            if(e->nr_fluxsteps > 1) {
                cuda_safe_call(cudaMemcpyAsync(e->part_species_flags_cuda[did], part_species_flags_cuda, sizeof(int) * s->nr_parts * nr_states, cudaMemcpyHostToDevice, stream));
            }
        }

    /* Start the clock. */
    // tic = getticks();
	}
    
    /* Lap the clock on the last stream. */
    cuda_safe_call(cudaEventRecord(toc_load, (cudaStream_t)e->streams[e->nr_devices-1]));

	/* Loop over the devices and call the different kernels on each stream. */
    for(did = 0 ; did < e->nr_devices ; did++) {

	    /* Set the device ID. */
        cuda_safe_call(cudaSetDevice(e->devices[did]));

        /* Get the stream. */
        stream = (cudaStream_t)e->streams[did];

        /* Clear the force array. */
        cuda_memset_float <<<8,512,0,stream>>>(e->forces_cuda[did], 0.0f, 4 * s->nr_parts);
        if(nr_states > 0) 
            cuda_memset_float<<<8,512,0,stream>>>(e->fluxes_next_cuda[did], 0.0f, nr_states * s->nr_parts);

        dim3 nr_threads(e->nr_threads[did], 1, 1);
        dim3 nr_blocks(std::min(e->nrtasks_cuda[did], e->nr_blocks[did]), 1, 1);

        if(e->s.verlet_rebuild)
            runner_run_cuda_do_sort_kernel<<<nr_blocks, nr_threads, maxcount * sizeof(unsigned int), stream>>>(e->counts_cuda[did], e->ind_cuda[did]);

        /* Do flux sub-steps if requested. */
        if(nr_states > 0 && e->nr_fluxsteps > 1) 
            for(e->step_flux = 0; e->step_flux < e->nr_fluxsteps - 1; e->step_flux++) {
                runner_run_cuda_do_self_fluxonly_kernel<<<nr_blocks, nr_threads, 2 * maxcount * sizeof(unsigned int), stream>>>(e->fluxes_next_cuda[did], nr_states, e->counts_cuda[did], e->ind_cuda[did]);
                runner_run_cuda_do_pair_left_fluxonly_kernel<<<nr_blocks, nr_threads, 2 * maxcount * sizeof(unsigned int), stream>>>(e->fluxes_next_cuda[did], nr_states, e->counts_cuda[did], e->ind_cuda[did], maxcount);
                runner_run_cuda_do_pair_right_fluxonly_kernel<<<nr_blocks, nr_threads, 2 * maxcount * sizeof(unsigned int), stream>>>(e->fluxes_next_cuda[did], nr_states, e->counts_cuda[did], e->ind_cuda[did], maxcount);
                runner_run_cuda_integrate_state_kernel<<<nr_blocks, nr_threads, 0, stream>>>(e->fluxes_next_cuda[did], e->part_species_flags_cuda[did], nr_states * s->nr_parts, e->dt_flux);
            }
        
        /* Start the appropriate kernel. */
        if(nr_states > 0) {
            runner_run_cuda_do_self_kernel<true><<<nr_blocks, nr_threads, 0, stream>>>(e->forces_cuda[did], e->fluxes_next_cuda[did], nr_states, e->counts_cuda[did], e->ind_cuda[did]);
            runner_run_cuda_do_pair_left_kernel<true><<<nr_blocks, nr_threads, 2 * maxcount * sizeof(unsigned int), stream>>>(e->forces_cuda[did], e->fluxes_next_cuda[did], nr_states, e->counts_cuda[did], e->ind_cuda[did], maxcount);
            runner_run_cuda_do_pair_right_kernel<true><<<nr_blocks, nr_threads, 2 * maxcount * sizeof(unsigned int), stream>>>(e->forces_cuda[did], e->fluxes_next_cuda[did], nr_states, e->counts_cuda[did], e->ind_cuda[did], maxcount);
        }
        else {
            runner_run_cuda_do_self_kernel<false><<<nr_blocks, nr_threads, 0, stream>>>(e->forces_cuda[did], e->fluxes_next_cuda[did], nr_states, e->counts_cuda[did], e->ind_cuda[did]);
            runner_run_cuda_do_pair_left_kernel<false><<<nr_blocks, nr_threads, 2 * maxcount * sizeof(unsigned int), stream>>>(e->forces_cuda[did], e->fluxes_next_cuda[did], nr_states, e->counts_cuda[did], e->ind_cuda[did], maxcount);
            runner_run_cuda_do_pair_right_kernel<false><<<nr_blocks, nr_threads, 2 * maxcount * sizeof(unsigned int), stream>>>(e->forces_cuda[did], e->fluxes_next_cuda[did], nr_states, e->counts_cuda[did], e->ind_cuda[did], maxcount);
        }
        cuda_safe_call(cudaPeekAtLastError());
    }

    // Initialize the return buffers while waiting
    for(did = 0; did < e->nr_devices ; did ++) {
        if((forces_cuda[did] = (float *)malloc(sizeof(float) * 4 * s->nr_parts)) == NULL)
            return error(MDCERR_malloc);
        if(nr_states > 0) {
            if((fluxes_next_cuda[did] = (float *)malloc(sizeof(float) * nr_states * s->nr_parts)) == NULL)
                return error(MDCERR_malloc);
            if(e->nr_fluxsteps > 1 && (part_states_next_cuda[did] = (float *)malloc(sizeof(float) * nr_states * s->nr_parts)) == NULL)
                return error(MDCERR_malloc);
            }
    }

	for(did = 0; did < e->nr_devices ; did ++) {
	
	    /* Set the device ID. */
        cuda_safe_call(cudaSetDevice(e->devices[did]));

        /* Get the stream. */
        stream = (cudaStream_t)e->streams[did];
        
        /* Get the forces from the device. */
        cuda_safe_call(cudaMemcpyAsync(forces_cuda[did], e->forces_cuda[did], sizeof(float) * 4 * s->nr_parts, cudaMemcpyDeviceToHost, stream));

        /* Get the potential energy. */
        cuda_safe_call(cudaMemcpyFromSymbolAsync(&epot[did], cuda_epot, sizeof(float), 0, cudaMemcpyDeviceToHost, stream));

        if(nr_states > 0) {
            // Get the flux data
            cuda_safe_call(cudaMemcpyAsync(fluxes_next_cuda[did], e->fluxes_next_cuda[did], sizeof(float) * nr_states * s->nr_parts, cudaMemcpyDeviceToHost, stream));
            if(e->nr_fluxsteps > 1) {
                cuda_safe_call(cudaMemcpyAsync(part_states_next_cuda[did], e->part_states_cuda[did], sizeof(float) * nr_states * s->nr_parts, cudaMemcpyDeviceToHost, stream));
            }
        }
        
    }

    std::vector<int> cell_counts;
    cell_counts.reserve(s->nr_cells);
    for(int k = 0; k < s->nr_cells; k++) {
        cell_counts.push_back(s->cells[k].count);
    }
    
    /* Lap the clock on the last stream. */
    cuda_safe_call(cudaEventRecord(toc_run, (cudaStream_t)e->streams[e->nr_devices-1]));
    
    /* Get and dump timers. */
    #ifdef TIMERS
        cuda_safe_call(cudaMemcpyFromSymbolAsync(timers, cuda_timers, sizeof(float) * tid_count, 0, cudaMemcpyDeviceToHost, (cudaStream_t)e->streams[0]));
        printf("engine_nonbond_cuda: timers = [ %.2f ", icpms * timers[0]);
        for(int k = 1 ; k < tid_count ; k++)
            printf("%.2f ", icpms * timers[k]);
        printf("] ms\n");
    #endif

    /* Check for any missed CUDA errors. */
    cuda_safe_call(cudaPeekAtLastError());
        

    /* Loop over the devices. */
    for(did = 0 ; did < e->nr_devices ; did++) {
    
        /* Get the stream. */
        stream = (cudaStream_t)e->streams[did];

        /* Wait for the chickens to come home to roost. */
        cuda_safe_call(cudaStreamSynchronize(stream));
    
        /* Get the potential energy. */
        e->s.epot += epot[did];

        auto _cells_cuda_local = e->cells_cuda_local[did];
        auto _forces_cuda = forces_cuda[did];
        auto _ind_cuda_local = e->ind_cuda_local[did];

        if(nr_states > 0) {
            auto _fluxes_next_cuda = fluxes_next_cuda[did];

            if(e->nr_fluxsteps > 1) {
                auto _part_states_next_cuda = part_states_next_cuda[did];

                auto func = [&_cells_cuda_local, &_forces_cuda, &_ind_cuda_local, nr_states, &_fluxes_next_cuda, &_part_states_next_cuda, &cell_counts, &cell_parts](int k) -> void {

                    /* Get the cell id. */
                    int cid = _cells_cuda_local[k];

                    /* Copy the particle data from the device. */
                    auto buff_force = &_forces_cuda[ 4*_ind_cuda_local[cid] ];
                    auto buff_flux = &_fluxes_next_cuda[nr_states * _ind_cuda_local[cid] ];
                    auto buff_state = &_part_states_next_cuda[nr_states * _ind_cuda_local[cid]];

                    for(int pid = 0 ; pid < cell_counts[cid] ; pid++) {
                        auto p = &cell_parts[cid][pid];
                        p->f[0] += buff_force[ 4*pid ];
                        p->f[1] += buff_force[ 4*pid + 1 ];
                        p->f[2] += buff_force[ 4*pid + 2 ];
                        p->f[3] += buff_force[ 4*pid + 3 ];

                        for(int fid = 0; fid < p->state_vector->size; fid++) {
                            p->state_vector->q[fid] += buff_flux[nr_states * pid + fid];
                            p->state_vector->fvec[fid] = buff_state[nr_states * pid + fid];
                        }
                    }

                };

                parallel_for(e->cells_cuda_nr[did], func);
            } 
            else {
                auto func = [&_cells_cuda_local, &_forces_cuda, &_ind_cuda_local, nr_states, &_fluxes_next_cuda, &cell_counts, &cell_parts](int k) -> void {

                    /* Get the cell id. */
                    int cid = _cells_cuda_local[k];

                    /* Copy the particle data from the device. */
                    auto buff_force = &_forces_cuda[ 4*_ind_cuda_local[cid] ];
                    auto buff_flux = &_fluxes_next_cuda[nr_states * _ind_cuda_local[cid] ];

                    for(int pid = 0 ; pid < cell_counts[cid] ; pid++) {
                        auto p = &cell_parts[cid][pid];
                        p->f[0] += buff_force[ 4*pid ];
                        p->f[1] += buff_force[ 4*pid + 1 ];
                        p->f[2] += buff_force[ 4*pid + 2 ];
                        p->f[3] += buff_force[ 4*pid + 3 ];

                        for(int fid = 0; fid < p->state_vector->size; fid++) 
                            p->state_vector->q[fid] += buff_flux[nr_states * pid + fid];
                    }

                };

                parallel_for(e->cells_cuda_nr[did], func);
            }
        } 
        else {
            auto func = [&_cells_cuda_local, &_forces_cuda, &_ind_cuda_local, &cell_counts, &cell_parts](int k) -> void {

                /* Get the cell id. */
                int cid = _cells_cuda_local[k];

                /* Copy the particle data from the device. */
                auto buff_force = &_forces_cuda[ 4*_ind_cuda_local[cid] ];
                for(int pid = 0 ; pid < cell_counts[cid] ; pid++) {
                    auto p = &cell_parts[cid][pid];
                    p->f[0] += buff_force[ 4*pid ];
                    p->f[1] += buff_force[ 4*pid + 1 ];
                    p->f[2] += buff_force[ 4*pid + 2 ];
                    p->f[3] += buff_force[ 4*pid + 3 ];
                }

            };

            parallel_for(e->cells_cuda_nr[did], func);
        }

        /* Deallocate the parts array and counts array. */
        free(forces_cuda[did]);
        if(nr_states > 0) {
            free(fluxes_next_cuda[did]);
            if(e->nr_fluxsteps > 1) 
                free(part_states_next_cuda[did]);
        }
        
    }
        
    /* Check for any missed CUDA errors. */
    cuda_safe_call(cudaPeekAtLastError());

    /* Stop the clock on the last stream. */
    if(cudaEventRecord(toc_unload, (cudaStream_t)e->streams[e->nr_devices-1]) != cudaSuccess ||
         cudaStreamSynchronize((cudaStream_t)e->streams[e->nr_devices-1]) != cudaSuccess)
        return cuda_error();
    
    /* Check for any missed CUDA errors. */
    cuda_safe_call(cudaPeekAtLastError());
        
    /* Store the timers. */
    if(cudaEventElapsedTime(&ms_load, tic, toc_load) != cudaSuccess ||
         cudaEventElapsedTime(&ms_run, toc_load, toc_run) != cudaSuccess ||
         cudaEventElapsedTime(&ms_unload, toc_run, toc_unload) != cudaSuccess)
        return cuda_error();
    e->timers[ engine_timer_cuda_load ] += ms_load / 1000 * CPU_TPS;
    e->timers[ engine_timer_cuda_dopairs ] += ms_run / 1000 * CPU_TPS;
    e->timers[ engine_timer_cuda_unload ] += ms_unload / 1000 * CPU_TPS;
    
    /* Go away. */
    return S_OK;
    
}

extern "C" HRESULT cuda::engine_cuda_load_parts(struct engine *e) {
    
    int k, did, maxcount = 0;
    float4* parts_pos_cuda = (float4*)e->parts_pos_cuda_local;
    float3* parts_vel_cuda = (float3*)e->parts_vel_cuda_local;
    int4* parts_datai_cuda = (int4*)e->parts_datai_cuda_local;
    struct space *s = &e->s;
    FPTYPE maxdist = s->cutoff + 2*s->maxdx;
    int *counts = e->counts_cuda_local[0], *inds = e->ind_cuda_local[0];
    cudaStream_t stream;
    
    /* Clear the counts array. */
    bzero(counts, sizeof(int) * s->nr_cells);

    /* Load the counts. */
    for(maxcount = 0, k = 0 ; k < s->nr_marked ; k++)
        if((counts[ s->cid_marked[k] ] = s->cells[ s->cid_marked[k] ].count) > maxcount)
            maxcount = counts[ s->cid_marked[k] ];

    /* Raise maxcount to the next multiple of 32. */
    maxcount =(maxcount + (cuda_frame - 1)) & ~(cuda_frame - 1);
    // printf("engine_cuda_load_parts: maxcount=%i.\n", maxcount);

    /* Compute the indices. */
    inds[0] = 0;
    for(k = 1 ; k < s->nr_cells ; k++)
        inds[k] = inds[k-1] + counts[k-1];

    /* Loop over the marked cells. */
    auto func_alloc_marked = [&] (int _k) -> void {

        /* Get the cell id. */
        int _cid = s->cid_marked[_k];

        /* Copy the particle data to the device. */
        auto buff_parts_pos_cuda = &parts_pos_cuda[inds[_cid]];
        auto buff_parts_vel_cuda = &parts_vel_cuda[inds[_cid]];
        auto buff_parts_datai_cuda = &parts_datai_cuda[inds[_cid]];
        for(int _pid = 0 ; _pid < counts[_cid] ; _pid++) {
            TissueForge::Particle* part = &s->cells[_cid].parts[_pid];
            buff_parts_pos_cuda[_pid] = {part->x[0], part->x[1], part->x[2], part->radius};
            buff_parts_vel_cuda[_pid] = {part->v[0], part->v[1], part->v[2]};
            buff_parts_datai_cuda[_pid] = {part->id, part->typeId, part->flags, part->clusterId};
        }

    };
    parallel_for(s->nr_marked, func_alloc_marked);

    // printf("engine_cuda_load_parts: packed %i cells with %i parts each (%i kB).\n", s->nr_cells, maxcount, (sizeof(float4)*maxcount*s->nr_cells)/1024);

    /* Loop over the devices. */
    for(did = 0 ; did < e->nr_devices ; did++) {
    
        /* Set the device ID. */
        cuda_safe_call(cudaSetDevice(e->devices[did]));

        /* Get the stream. */
        stream = (cudaStream_t)e->streams[did];
        
        /* Start by setting the maxdist on the device. */
        cuda_safe_call(cudaMemcpyToSymbolAsync(cuda_maxdist, &maxdist, sizeof(float), 0, cudaMemcpyHostToDevice, stream));

        /* Copy the counts onto the device. */
        cuda_safe_call(cudaMemcpyAsync(e->counts_cuda[did], counts, sizeof(int) * s->nr_cells, cudaMemcpyHostToDevice, stream));

        /* Copy the inds onto the device. */
        cuda_safe_call(cudaMemcpyAsync(e->ind_cuda[did], inds, sizeof(int) * s->nr_cells, cudaMemcpyHostToDevice, stream));

        /* Bind the particle positions. */
        cuda_safe_call(cudaMemcpyAsync(e->parts_pos_cuda[did], parts_pos_cuda, sizeof(float4) * s->nr_parts, cudaMemcpyHostToDevice, stream));
        cuda_safe_call(cudaMemcpyAsync(e->parts_vel_cuda[did], parts_vel_cuda, sizeof(float3) * s->nr_parts, cudaMemcpyHostToDevice, stream));
        cuda_safe_call(cudaMemcpyAsync(e->parts_datai_cuda[did], parts_datai_cuda, sizeof(int4) * s->nr_parts, cudaMemcpyHostToDevice, stream));

        /* Clear the force array. */
        cuda_safe_call(cudaMemsetAsync(e->forces_cuda[did], 0, sizeof(float) * 4 * s->nr_parts, stream));

    }
    
    /* Our work is done here. */
    return S_OK;

}

extern "C" HRESULT cuda::engine_cuda_unload_parts(struct engine *e) {

    int k, did, cid, pid;
    struct TissueForge::Particle *p;
    float *forces_cuda[ engine_maxgpu ], *buff, epot[ engine_maxgpu ];
    struct space *s = &e->s;
    cudaStream_t stream;
    
    /* Loop over the devices. */
    for(did = 0 ; did < e->nr_devices ; did++) {
    
        /* Set the device ID. */
        cuda_safe_call(cudaSetDevice(e->devices[did]));

        /* Get the stream. */
        stream = (cudaStream_t)e->streams[did];
    
        /* Get the forces from the device. */
        if((forces_cuda[did] = (float *)malloc(sizeof(float) * 4 * s->nr_parts)) == NULL)
            return error(MDCERR_malloc);
        cuda_safe_call(cudaMemcpyAsync(forces_cuda[did], e->forces_cuda[did], sizeof(float) * 4 * s->nr_parts, cudaMemcpyDeviceToHost, stream));

        /* Get the potential energy. */
        cuda_safe_call(cudaMemcpyFromSymbolAsync(&epot[did], cuda_epot, sizeof(float), 0, cudaMemcpyDeviceToHost, stream));
        
    }

    /* Loop over the devices. */
    for(did = 0 ; did < e->nr_devices ; did++) {
    
        /* Get the stream. */
        stream = (cudaStream_t)e->streams[did];

        /* Wait for the chickens to come home to roost. */
        cuda_safe_call(cudaStreamSynchronize(stream));
    
        /* Get the potential energy. */
        e->s.epot += epot[did];
        
        /* Loop over the marked cells. */
        for(k = 0 ; k < s->nr_marked ; k++) {

            /* Get the cell id. */
            cid = s->cid_marked[k];

            /* Copy the particle data from the device. */
            buff = &forces_cuda[did][ 4*e->ind_cuda_local[did][cid] ];
            for(pid = 0 ; pid < s->cells[cid].count ; pid++) {
                p = &s->cells[cid].parts[pid];
                p->f[0] += buff[ 4*pid ];
                p->f[1] += buff[ 4*pid + 1 ];
                p->f[2] += buff[ 4*pid + 2 ];
                p->f[3] += buff[ 4*pid + 3 ];
                }

            }

        /* Deallocate the parts array and counts array. */
        free(forces_cuda[did]);
        
    }
        
    /* Our work is done here. */
    return S_OK;

}


extern "C" HRESULT cuda::engine_cuda_load_pots(struct engine *e) {
    int nr_pots, nr_pots_cluster;
    std::vector<int> pind, pind_cluster;

    // Pack the potentials

    int max_coeffs, max_pots, max_dpds;
    int max_coeffs_cluster, max_pots_cluster, max_dpds_cluster;
    std::vector<float> pot_alpha, pot_alpha_cluster;
    std::vector<float> pot_c, pot_c_cluster;
    std::vector<float> pot_dataf, pot_dataf_cluster;
    std::vector<int> pot_datai, pot_datai_cluster;
    std::vector<float> dpd_cf, dpd_cf_cluster;
    std::vector<float> dpd_dataf, dpd_dataf_cluster;
    std::vector<int> dpd_datai, dpd_datai_cluster;
    cuda_safe_call_e(engine_cuda_build_pots_pack(
        e->p, e->max_type * e->max_type, 
        pind, pot_alpha, pot_c, pot_dataf, pot_datai, 
        dpd_cf, dpd_dataf, dpd_datai, 
        max_coeffs, max_pots, max_dpds, nr_pots), S_OK);
    cuda_safe_call_e(engine_cuda_build_pots_pack(
        e->p_cluster, e->max_type * e->max_type, 
        pind_cluster, pot_alpha_cluster, pot_c_cluster, pot_dataf_cluster, pot_datai_cluster, 
        dpd_cf_cluster, dpd_dataf_cluster, dpd_datai_cluster, 
        max_coeffs_cluster, max_pots_cluster, max_dpds_cluster, nr_pots_cluster), S_OK);
    
    /* Store pind as a constant. */

    for(int did = 0 ; did < e->nr_devices ; did++) {
        cuda_safe_call(cudaSetDevice(e->devices[did]));
        cuda_safe_call(cudaMalloc(&e->pind_cuda[did], sizeof(int) * pind.size()));
        cuda_safe_call(cudaMemcpy(e->pind_cuda[did], pind.data(), sizeof(int) * pind.size(), cudaMemcpyHostToDevice));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_pind, &e->pind_cuda[did], sizeof(int *), 0, cudaMemcpyHostToDevice));
    }
    
    for(int did = 0 ; did < e->nr_devices ; did++) {
        cuda_safe_call(cudaSetDevice(e->devices[did]));
        cuda_safe_call(cudaMalloc(&e->pind_cluster_cuda[did], sizeof(int) * pind_cluster.size()));
        cuda_safe_call(cudaMemcpy(e->pind_cluster_cuda[did], pind_cluster.data(), sizeof(int) * pind_cluster.size(), cudaMemcpyHostToDevice));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_pind_cluster, &e->pind_cluster_cuda[did], sizeof(int *), 0, cudaMemcpyHostToDevice));
    }

    // Store the potentials

    cudaChannelFormatDesc channelDesc_int = cudaCreateChannelDesc<int>();
    cudaChannelFormatDesc channelDesc_float = cudaCreateChannelDesc<float>();

    for(int did = 0 ; did < e->nr_devices ; did++) {
        cuda_safe_call(cudaSetDevice(e->devices[did]));

        cuda_safe_call(cudaMallocArray(&cuda_pot_alpha[did], &channelDesc_float, ENGINE_CUDA_POT_WIDTH_ALPHA, pot_alpha.size() / ENGINE_CUDA_POT_WIDTH_ALPHA, 0));
        cuda_safe_call(cudaMemcpy2DToArray(cuda_pot_alpha[did], 0, 0, pot_alpha.data(), sizeof(float) * ENGINE_CUDA_POT_WIDTH_ALPHA, sizeof(float) * ENGINE_CUDA_POT_WIDTH_ALPHA, pot_alpha.size() / ENGINE_CUDA_POT_WIDTH_ALPHA, cudaMemcpyHostToDevice));
        cuda_safe_call_e(engine_cuda_texture_init(&tex_pot_alpha[did], cuda_pot_alpha[did]), S_OK);
        cuda_safe_call(cudaMemcpyToSymbol(cuda_tex_pot_alpha, &tex_pot_alpha[did], sizeof(cudaTextureObject_t), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMallocArray(&cuda_pot_cluster_alpha[did], &channelDesc_float, ENGINE_CUDA_POT_WIDTH_ALPHA, pot_alpha_cluster.size() / ENGINE_CUDA_POT_WIDTH_ALPHA, 0));
        cuda_safe_call(cudaMemcpy2DToArray(cuda_pot_cluster_alpha[did], 0, 0, pot_alpha_cluster.data(), sizeof(float) * ENGINE_CUDA_POT_WIDTH_ALPHA, sizeof(float) * ENGINE_CUDA_POT_WIDTH_ALPHA, pot_alpha_cluster.size() / ENGINE_CUDA_POT_WIDTH_ALPHA, cudaMemcpyHostToDevice));
        cuda_safe_call_e(engine_cuda_texture_init(&tex_pot_cluster_alpha[did], cuda_pot_cluster_alpha[did]), S_OK);
        cuda_safe_call(cudaMemcpyToSymbol(cuda_tex_pot_cluster_alpha, &tex_pot_cluster_alpha[did], sizeof(cudaTextureObject_t), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMallocArray(&cuda_pot_c[did], &channelDesc_float, potential_chunk * max_coeffs, pot_c.size() / (potential_chunk * max_coeffs), 0));
        cuda_safe_call(cudaMemcpy2DToArray(cuda_pot_c[did], 0, 0, pot_c.data(), sizeof(float) * potential_chunk * max_coeffs, sizeof(float) * potential_chunk * max_coeffs, pot_c.size() / (potential_chunk * max_coeffs), cudaMemcpyHostToDevice));
        cuda_safe_call_e(engine_cuda_texture_init(&tex_pot_c[did], cuda_pot_c[did]), S_OK);
        cuda_safe_call(cudaMemcpyToSymbol(cuda_tex_pot_c, &tex_pot_c[did], sizeof(cudaTextureObject_t), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMallocArray(&cuda_pot_cluster_c[did], &channelDesc_float, potential_chunk * max_coeffs_cluster, pot_c_cluster.size() / (potential_chunk * max_coeffs_cluster), 0));
        cuda_safe_call(cudaMemcpy2DToArray(cuda_pot_cluster_c[did], 0, 0, pot_c_cluster.data(), sizeof(float) * potential_chunk * max_coeffs_cluster, sizeof(float) * potential_chunk * max_coeffs_cluster, pot_c_cluster.size() / (potential_chunk * max_coeffs_cluster), cudaMemcpyHostToDevice));
        cuda_safe_call_e(engine_cuda_texture_init(&tex_pot_cluster_c[did], cuda_pot_cluster_c[did]), S_OK);
        cuda_safe_call(cudaMemcpyToSymbol(cuda_tex_pot_cluster_c, &tex_pot_cluster_c[did], sizeof(cudaTextureObject_t), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMallocArray(&cuda_pot_dataf[did], &channelDesc_float, ENGINE_CUDA_POT_WIDTH_DATAF, pot_dataf.size() / ENGINE_CUDA_POT_WIDTH_DATAF, 0));
        cuda_safe_call(cudaMemcpy2DToArray(cuda_pot_dataf[did], 0, 0, pot_dataf.data(), sizeof(float) * ENGINE_CUDA_POT_WIDTH_DATAF, sizeof(float) * ENGINE_CUDA_POT_WIDTH_DATAF, pot_dataf.size() / ENGINE_CUDA_POT_WIDTH_DATAF, cudaMemcpyHostToDevice));
        cuda_safe_call_e(engine_cuda_texture_init(&tex_pot_dataf[did], cuda_pot_dataf[did]), S_OK);
        cuda_safe_call(cudaMemcpyToSymbol(cuda_tex_pot_dataf, &tex_pot_dataf[did], sizeof(cudaTextureObject_t), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMallocArray(&cuda_pot_cluster_dataf[did], &channelDesc_float, ENGINE_CUDA_POT_WIDTH_DATAF, pot_dataf_cluster.size() / ENGINE_CUDA_POT_WIDTH_DATAF, 0));
        cuda_safe_call(cudaMemcpy2DToArray(cuda_pot_cluster_dataf[did], 0, 0, pot_dataf_cluster.data(), sizeof(float) * ENGINE_CUDA_POT_WIDTH_DATAF, sizeof(float) * ENGINE_CUDA_POT_WIDTH_DATAF, pot_dataf_cluster.size() / ENGINE_CUDA_POT_WIDTH_DATAF, cudaMemcpyHostToDevice));
        cuda_safe_call_e(engine_cuda_texture_init(&tex_pot_cluster_dataf[did], cuda_pot_cluster_dataf[did]), S_OK);
        cuda_safe_call(cudaMemcpyToSymbol(cuda_tex_pot_cluster_dataf, &tex_pot_cluster_dataf[did], sizeof(cudaTextureObject_t), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMallocArray(&cuda_pot_datai[did], &channelDesc_int, ENGINE_CUDA_POT_WIDTH_DATAI, pot_datai.size() / ENGINE_CUDA_POT_WIDTH_DATAI, 0));
        cuda_safe_call(cudaMemcpy2DToArray(cuda_pot_datai[did], 0, 0, pot_datai.data(), sizeof(int) * ENGINE_CUDA_POT_WIDTH_DATAI, sizeof(int) * ENGINE_CUDA_POT_WIDTH_DATAI, pot_datai.size() / ENGINE_CUDA_POT_WIDTH_DATAI, cudaMemcpyHostToDevice));
        cuda_safe_call_e(engine_cuda_texture_init(&tex_pot_datai[did], cuda_pot_datai[did]), S_OK);
        cuda_safe_call(cudaMemcpyToSymbol(cuda_tex_pot_datai, &tex_pot_datai[did], sizeof(cudaTextureObject_t), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMallocArray(&cuda_pot_cluster_datai[did], &channelDesc_int, ENGINE_CUDA_POT_WIDTH_DATAI, pot_datai_cluster.size() / ENGINE_CUDA_POT_WIDTH_DATAI, 0));
        cuda_safe_call(cudaMemcpy2DToArray(cuda_pot_cluster_datai[did], 0, 0, pot_datai_cluster.data(), sizeof(int) * ENGINE_CUDA_POT_WIDTH_DATAI, sizeof(int) * ENGINE_CUDA_POT_WIDTH_DATAI, pot_datai_cluster.size() / ENGINE_CUDA_POT_WIDTH_DATAI, cudaMemcpyHostToDevice));
        cuda_safe_call_e(engine_cuda_texture_init(&tex_pot_cluster_datai[did], cuda_pot_cluster_datai[did]), S_OK);
        cuda_safe_call(cudaMemcpyToSymbol(cuda_tex_pot_cluster_datai, &tex_pot_cluster_datai[did], sizeof(cudaTextureObject_t), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMallocArray(&cuda_dpd_cfs[did], &channelDesc_float, ENGINE_CUDA_DPD_WIDTH_CF, dpd_cf.size() / ENGINE_CUDA_DPD_WIDTH_CF, 0));
        cuda_safe_call(cudaMemcpy2DToArray(cuda_dpd_cfs[did], 0, 0, dpd_cf.data(), sizeof(float) * ENGINE_CUDA_DPD_WIDTH_CF, sizeof(float) * ENGINE_CUDA_DPD_WIDTH_CF, dpd_cf.size() / ENGINE_CUDA_DPD_WIDTH_CF, cudaMemcpyHostToDevice));
        cuda_safe_call_e(engine_cuda_texture_init(&tex_dpd_cfs[did], cuda_dpd_cfs[did]), S_OK);
        cuda_safe_call(cudaMemcpyToSymbol(cuda_tex_dpd_cfs, &tex_dpd_cfs[did], sizeof(cudaTextureObject_t), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMallocArray(&cuda_dpd_cluster_cfs[did], &channelDesc_float, ENGINE_CUDA_DPD_WIDTH_CF, dpd_cf_cluster.size() / ENGINE_CUDA_DPD_WIDTH_CF, 0));
        cuda_safe_call(cudaMemcpy2DToArray(cuda_dpd_cluster_cfs[did], 0, 0, dpd_cf_cluster.data(), sizeof(float) * ENGINE_CUDA_DPD_WIDTH_CF, sizeof(float) * ENGINE_CUDA_DPD_WIDTH_CF, dpd_cf_cluster.size() / ENGINE_CUDA_DPD_WIDTH_CF, cudaMemcpyHostToDevice));
        cuda_safe_call_e(engine_cuda_texture_init(&tex_dpd_cluster_cfs[did], cuda_dpd_cluster_cfs[did]), S_OK);
        cuda_safe_call(cudaMemcpyToSymbol(cuda_tex_dpd_cluster_cfs, &tex_dpd_cluster_cfs[did], sizeof(cudaTextureObject_t), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMallocArray(&cuda_dpd_dataf[did], &channelDesc_float, ENGINE_CUDA_DPD_WIDTH_DATAF, dpd_dataf.size() / ENGINE_CUDA_DPD_WIDTH_DATAF, 0));
        cuda_safe_call(cudaMemcpy2DToArray(cuda_dpd_dataf[did], 0, 0, dpd_dataf.data(), sizeof(float) * ENGINE_CUDA_DPD_WIDTH_DATAF, sizeof(float) * ENGINE_CUDA_DPD_WIDTH_DATAF, dpd_dataf.size() / ENGINE_CUDA_DPD_WIDTH_DATAF, cudaMemcpyHostToDevice));
        cuda_safe_call_e(engine_cuda_texture_init(&tex_dpd_dataf[did], cuda_dpd_dataf[did]), S_OK);
        cuda_safe_call(cudaMemcpyToSymbol(cuda_tex_dpd_dataf, &tex_dpd_dataf[did], sizeof(cudaTextureObject_t), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMallocArray(&cuda_dpd_cluster_dataf[did], &channelDesc_float, ENGINE_CUDA_DPD_WIDTH_DATAF, dpd_dataf_cluster.size() / ENGINE_CUDA_DPD_WIDTH_DATAF, 0));
        cuda_safe_call(cudaMemcpy2DToArray(cuda_dpd_cluster_dataf[did], 0, 0, dpd_dataf_cluster.data(), sizeof(float) * ENGINE_CUDA_DPD_WIDTH_DATAF, sizeof(float) * ENGINE_CUDA_DPD_WIDTH_DATAF, dpd_dataf_cluster.size() / ENGINE_CUDA_DPD_WIDTH_DATAF, cudaMemcpyHostToDevice));
        cuda_safe_call_e(engine_cuda_texture_init(&tex_dpd_cluster_dataf[did], cuda_dpd_cluster_dataf[did]), S_OK);
        cuda_safe_call(cudaMemcpyToSymbol(cuda_tex_dpd_cluster_dataf, &tex_dpd_cluster_dataf[did], sizeof(cudaTextureObject_t), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMallocArray(&cuda_dpd_datai[did], &channelDesc_int, ENGINE_CUDA_DPD_WIDTH_DATAI, dpd_datai.size() / ENGINE_CUDA_DPD_WIDTH_DATAI, 0));
        cuda_safe_call(cudaMemcpy2DToArray(cuda_dpd_datai[did], 0, 0, dpd_datai.data(), sizeof(int) * ENGINE_CUDA_DPD_WIDTH_DATAI, sizeof(int) * ENGINE_CUDA_DPD_WIDTH_DATAI, dpd_datai.size() / ENGINE_CUDA_DPD_WIDTH_DATAI, cudaMemcpyHostToDevice));
        cuda_safe_call_e(engine_cuda_texture_init(&tex_dpd_datai[did], cuda_dpd_datai[did]), S_OK);
        cuda_safe_call(cudaMemcpyToSymbol(cuda_tex_dpd_datai, &tex_dpd_datai[did], sizeof(cudaTextureObject_t), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMallocArray(&cuda_dpd_cluster_datai[did], &channelDesc_int, ENGINE_CUDA_DPD_WIDTH_DATAI, dpd_datai_cluster.size() / ENGINE_CUDA_DPD_WIDTH_DATAI, 0));
        cuda_safe_call(cudaMemcpy2DToArray(cuda_dpd_cluster_datai[did], 0, 0, dpd_datai_cluster.data(), sizeof(int) * ENGINE_CUDA_DPD_WIDTH_DATAI, sizeof(int) * ENGINE_CUDA_DPD_WIDTH_DATAI, dpd_datai_cluster.size() / ENGINE_CUDA_DPD_WIDTH_DATAI, cudaMemcpyHostToDevice));
        cuda_safe_call_e(engine_cuda_texture_init(&tex_dpd_cluster_datai[did], cuda_dpd_cluster_datai[did]), S_OK);
        cuda_safe_call(cudaMemcpyToSymbol(cuda_tex_dpd_cluster_datai, &tex_dpd_cluster_datai[did], sizeof(cudaTextureObject_t), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMemcpyToSymbol(cuda_pots_max, &max_pots, sizeof(int), 0, cudaMemcpyHostToDevice));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_pots_cluster_max, &max_pots_cluster, sizeof(int), 0, cudaMemcpyHostToDevice));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_dpds_max, &max_dpds, sizeof(int), 0, cudaMemcpyHostToDevice));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_dpds_cluster_max, &max_dpds_cluster, sizeof(int), 0, cudaMemcpyHostToDevice));
    }
    
    e->nr_pots_cuda = nr_pots;
    e->nr_pots_cluster_cuda = nr_pots_cluster;

    return S_OK;
}

extern "C" HRESULT cuda::engine_cuda_unload_pots(struct engine *e) {

    for(int did = 0; did < e->nr_devices; did++) {

        cuda_safe_call(cudaSetDevice(e->devices[did]));

        // Free the potentials.

        cuda_safe_call_e(engine_cuda_texture_finalize(tex_pot_alpha[did]), S_OK);
        cuda_safe_call(cudaFreeArray(cuda_pot_alpha[did]));

        cuda_safe_call_e(engine_cuda_texture_finalize(tex_pot_cluster_alpha[did]), S_OK);
        cuda_safe_call(cudaFreeArray(cuda_pot_cluster_alpha[did]));

        cuda_safe_call_e(engine_cuda_texture_finalize(tex_pot_c[did]), S_OK);
        cuda_safe_call(cudaFreeArray(cuda_pot_c[did]));

        cuda_safe_call_e(engine_cuda_texture_finalize(tex_pot_cluster_c[did]), S_OK);
        cuda_safe_call(cudaFreeArray(cuda_pot_cluster_c[did]));

        cuda_safe_call_e(engine_cuda_texture_finalize(tex_pot_dataf[did]), S_OK);
        cuda_safe_call(cudaFreeArray(cuda_pot_dataf[did]));

        cuda_safe_call_e(engine_cuda_texture_finalize(tex_pot_cluster_dataf[did]), S_OK);
        cuda_safe_call(cudaFreeArray(cuda_pot_cluster_dataf[did]));

        cuda_safe_call_e(engine_cuda_texture_finalize(tex_pot_datai[did]), S_OK);
        cuda_safe_call(cudaFreeArray(cuda_pot_datai[did]));

        cuda_safe_call_e(engine_cuda_texture_finalize(tex_pot_cluster_datai[did]), S_OK);
        cuda_safe_call(cudaFreeArray(cuda_pot_cluster_datai[did]));

        cuda_safe_call_e(engine_cuda_texture_finalize(tex_dpd_cfs[did]), S_OK);
        cuda_safe_call(cudaFreeArray(cuda_dpd_cfs[did]));

        cuda_safe_call_e(engine_cuda_texture_finalize(tex_dpd_cluster_cfs[did]), S_OK);
        cuda_safe_call(cudaFreeArray(cuda_dpd_cluster_cfs[did]));

        cuda_safe_call_e(engine_cuda_texture_finalize(tex_dpd_dataf[did]), S_OK);
        cuda_safe_call(cudaFreeArray(cuda_dpd_dataf[did]));

        cuda_safe_call_e(engine_cuda_texture_finalize(tex_dpd_cluster_dataf[did]), S_OK);
        cuda_safe_call(cudaFreeArray(cuda_dpd_cluster_dataf[did]));

        cuda_safe_call_e(engine_cuda_texture_finalize(tex_dpd_datai[did]), S_OK);
        cuda_safe_call(cudaFreeArray(cuda_dpd_datai[did]));

        cuda_safe_call_e(engine_cuda_texture_finalize(tex_dpd_cluster_datai[did]), S_OK);
        cuda_safe_call(cudaFreeArray(cuda_dpd_cluster_datai[did]));
        
        cuda_safe_call(::cudaFree(e->pind_cuda[did]));
        
        cuda_safe_call(::cudaFree(e->pind_cluster_cuda[did]));

    }

    e->nr_pots_cuda = 0;
    e->nr_pots_cluster_cuda = 0;

    return S_OK;
}

extern "C" HRESULT cuda::engine_cuda_refresh_pots(struct engine *e) {
    
    if(engine_cuda_unload_pots(e) < 0)
        return error(MDCERR_cuda);

    if(engine_cuda_load_pots(e) < 0)
        return error(MDCERR_cuda);

    for(int did = 0; did < e->nr_devices; did++) {

        cuda_safe_call(cudaSetDevice(e->devices[did]));

        cuda_safe_call(cudaDeviceSynchronize());

    }

    return S_OK;
}


/**
 * @brief Allocates particle buffers. Must be called before running on a CUDA device. 
 * 
 * @param e The #engine
 */
HRESULT engine_cuda_allocate_particles(struct engine *e) {

    /* Allocate the particle buffer. */
    if((e->parts_pos_cuda_local = malloc(sizeof(float4) * e->s.size_parts)) == NULL) 
        return error(MDCERR_malloc);
    if((e->parts_vel_cuda_local = malloc(sizeof(float3) * e->s.size_parts)) == NULL) 
        return error(MDCERR_malloc);
    if((e->parts_datai_cuda_local = malloc(sizeof(int4) * e->s.size_parts)) == NULL) 
        return error(MDCERR_malloc);

    /* Allocate the particle and force data. */
    for(int did = 0; did < e->nr_devices; did++) {
        cuda_safe_call (cudaSetDevice(e->devices[did]));
        cuda_safe_call (cudaMalloc(&e->parts_pos_cuda[did], sizeof(float4) * e->s.size_parts));
        cuda_safe_call (cudaMemcpyToSymbol(cuda_parts_pos, &e->parts_pos_cuda[did], sizeof(float4*), 0, cudaMemcpyHostToDevice));
        cuda_safe_call (cudaMalloc(&e->parts_vel_cuda[did], sizeof(float3) * e->s.size_parts));
        cuda_safe_call (cudaMemcpyToSymbol(cuda_parts_vel, &e->parts_vel_cuda[did], sizeof(float3*), 0, cudaMemcpyHostToDevice));
        cuda_safe_call (cudaMalloc(&e->parts_datai_cuda[did], sizeof(int4) * e->s.size_parts));
        cuda_safe_call (cudaMemcpyToSymbol(cuda_parts_datai, &e->parts_datai_cuda[did], sizeof(int4*), 0, cudaMemcpyHostToDevice));
        cuda_safe_call (cudaMalloc(&e->forces_cuda[did], sizeof(float) * 4 * e->s.size_parts));
    }

    return S_OK;
}


/**
 * @brief Closes particle buffers. 
 * 
 * @param e The #engine
 */
HRESULT engine_cuda_finalize_particles(struct engine *e) {

    for(int did = 0; did < e->nr_devices; did++) {

        cuda_safe_call(cudaSetDevice(e->devices[did]));

        // Free the particle and force data

        cuda_safe_call(cudaFree(e->parts_pos_cuda[did]));
        cuda_safe_call(cudaFree(e->parts_vel_cuda[did]));
        cuda_safe_call(cudaFree(e->parts_datai_cuda[did]));
        cuda_safe_call(cudaFree(e->forces_cuda[did]));

    }

    // Free the particle buffer

    free(e->parts_pos_cuda_local);
    free(e->parts_vel_cuda_local);
    free(e->parts_datai_cuda_local);

    return S_OK;
}

extern "C" HRESULT cuda::engine_cuda_refresh_particles(struct engine *e) {

    if(engine_cuda_finalize_particles(e) < 0)
        return cuda_error();

    if(engine_cuda_allocate_particles(e) < 0)
        return cuda_error();

    bool is_stateful = e->nr_fluxes_cuda > 1;

    if(is_stateful && engine_cuda_refresh_particle_states(e) < 0) 
        return error(MDCERR_cuda);

    for(int did = 0; did < e->nr_devices; did++) {

        cuda_safe_call(cudaSetDevice(e->devices[did]));

        cuda_safe_call(cudaDeviceSynchronize());

    }

    return S_OK;
}

extern "C" HRESULT cuda::engine_cuda_allocate_particle_states(struct engine *e) {
    int nr_states = e->nr_fluxes_cuda - 1;

    if(nr_states <= 0 || nr_states == engine_cuda_nr_states) 
        return S_OK;

    if(engine_cuda_nr_states > 0) 
        if(engine_cuda_finalize_particle_states(e) < 0) 
            return error(MDCERR_cuda);
    
    if((e->part_states_cuda_local = (float*)malloc(sizeof(float) * e->s.size_parts * nr_states)) == NULL)
        return error(MDCERR_malloc);
    if(e->nr_fluxsteps > 1 && (e->part_species_flags_cuda_local = (int*)malloc(sizeof(int) * e->s.size_parts * nr_states)) == NULL) 
        return error(MDCERR_malloc);

    for(int did = 0; did < e->nr_devices; did++) {

        cuda_safe_call (cudaMalloc(&e->part_states_cuda[did], sizeof(float) * e->s.size_parts * nr_states));
        
        cuda_safe_call (cudaMemcpyToSymbol(cuda_part_states, &e->part_states_cuda[did], sizeof(float *), 0, cudaMemcpyHostToDevice));

        if(e->nr_fluxsteps > 1) {
            cuda_safe_call(cudaMalloc(&e->part_species_flags_cuda[did], sizeof(int) * e->s.size_parts * nr_states));
        }
    }

    engine_cuda_nr_states = nr_states;

    return S_OK;
}

extern "C" HRESULT cuda::engine_cuda_finalize_particle_states(struct engine *e) {
    if(engine_cuda_nr_states == 0) 
        return S_OK;

    for(int did = 0; did < e->nr_devices; did++) {

        cuda_safe_call(cudaSetDevice(e->devices[did]));

        cuda_safe_call(::cudaFree(e->part_states_cuda[did]));

        if(e->nr_fluxsteps > 1) {
            cuda_safe_call(::cudaFree(e->part_species_flags_cuda[did]));
        }
    }

    // Free the particle buffer

    free(e->part_states_cuda_local);

    if(e->nr_fluxsteps > 1) 
        free(e->part_species_flags_cuda_local);

    engine_cuda_nr_states = 0;

    return S_OK;
}

extern "C" HRESULT cuda::engine_cuda_refresh_particle_states(struct engine *e) {
    if(engine_cuda_finalize_particle_states(e) < 0)
        return cuda_error();

    if(engine_cuda_allocate_particle_states(e) < 0)
        return cuda_error();

    for(int did = 0; did < e->nr_devices; did++) {

        cuda_safe_call(cudaSetDevice(e->devices[did]));

        cuda_safe_call(cudaDeviceSynchronize());

    }

    return S_OK;
}

extern "C" HRESULT cuda::engine_cuda_load(struct engine *e) {

    int i, k, nr_tasks, c1,c2;
    int did, *cellsorts;
    struct space *s = &e->s;
    int nr_devices = e->nr_devices;
    struct task_cuda *tasks_cuda, *tc, *ts;
    struct task *t;
    float dt = e->dt, cutoff = e->s.cutoff, cutoff2 = e->s.cutoff2, dscale; //, buff[ e->nr_types ];
    float h[3], dim[3], *corig;
    void *dummy[ engine_maxgpu ];
    unsigned int *cflags, nr_cells = s->nr_cells, dmaxdist;
    float3 *cdims;

    /*Split the space over the available GPUs*/
    engine_split_gpu(e, nr_devices, engine_split_GPU);
    
    /* Copy the cell edge lengths to the device. */
    h[0] = s->h[0]*s->span[0];
    h[1] = s->h[1]*s->span[1];
    h[2] = s->h[2]*s->span[2];
    dim[0] = s->dim[0]; dim[1] = s->dim[1]; dim[2] = s->dim[2];
    for(did = 0 ; did < nr_devices ; did++) {
        cuda_safe_call(cudaSetDevice(e->devices[did]));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_h, h, sizeof(float) * 3, 0, cudaMemcpyHostToDevice));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_dim, dim, sizeof(float) * 3, 0, cudaMemcpyHostToDevice));
    }

    /* Copy the cell origins, dimensions and flags to the device. */
    if((corig = (float *)malloc(sizeof(float) * s->nr_cells * 3)) == NULL)
        return error(MDCERR_malloc);
    if((cdims = (float3*)malloc(sizeof(float3) * s->nr_cells)) == NULL)
        return error(MDCERR_malloc);
    if((cflags = (unsigned int*)malloc(sizeof(unsigned int) * s->nr_cells)) == NULL)
        return error(MDCERR_malloc);
    
    auto func_copy_cell_data = [&s, &corig, &cdims, &cflags](int _i) -> void {
        corig[3*_i + 0] = s->cells[_i].origin[0];
        corig[3*_i + 1] = s->cells[_i].origin[1];
        corig[3*_i + 2] = s->cells[_i].origin[2];
        cdims[_i] = make_float3(s->cells[_i].dim[0], s->cells[_i].dim[1], s->cells[_i].dim[2]);
        cflags[_i] = s->cells[_i].flags;
    };
    parallel_for(s->nr_cells, func_copy_cell_data);

    for(did = 0 ; did < nr_devices ; did++) {
        cuda_safe_call(cudaSetDevice(e->devices[did]));

        cuda_safe_call(cudaMalloc(&dummy[did], sizeof(float) * s->nr_cells * 3));
        cuda_safe_call(cudaMemcpy(dummy[did], corig, sizeof(float) * s->nr_cells * 3, cudaMemcpyHostToDevice));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_corig, &dummy[did], sizeof(float *), 0, cudaMemcpyHostToDevice));
        
        cuda_safe_call(cudaMalloc(&dummy[did], sizeof(float3) * s->nr_cells));
        cuda_safe_call(cudaMemcpy(dummy[did], cdims, sizeof(float3) * s->nr_cells, cudaMemcpyHostToDevice));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_cdims, &dummy[did], sizeof(float3 *), 0, cudaMemcpyHostToDevice));
        
        cuda_safe_call(cudaMalloc(&dummy[did], sizeof(unsigned int) * s->nr_cells));
        cuda_safe_call(cudaMemcpy(dummy[did], cflags, sizeof(unsigned int) * s->nr_cells, cudaMemcpyHostToDevice));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_cflags, &dummy[did], sizeof(unsigned int *), 0, cudaMemcpyHostToDevice));
    }
    free(corig);
    free(cdims);
    free(cflags);
        
    /* Set the constant pointer to the null potential and other useful values. */
    dscale = ((float)SHRT_MAX) /(3.0 * sqrt(s->h[0]*s->h[0]*s->span[0]*s->span[0] + s->h[1]*s->h[1]*s->span[1]*s->span[1] + s->h[2]*s->h[2]*s->span[2]*s->span[2]));
    dmaxdist = 2 + dscale * cutoff;
    for(did = 0 ;did < nr_devices ; did++) {
        cuda_safe_call(cudaSetDevice(e->devices[did]));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_dt, &dt, sizeof(float), 0, cudaMemcpyHostToDevice));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_cutoff, &cutoff, sizeof(float), 0, cudaMemcpyHostToDevice));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_cutoff2, &cutoff2, sizeof(float), 0, cudaMemcpyHostToDevice));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_maxdist, &cutoff, sizeof(float), 0, cudaMemcpyHostToDevice));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_dmaxdist, &dmaxdist, sizeof(unsigned int), 0, cudaMemcpyHostToDevice));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_maxtype, &(e->max_type), sizeof(int), 0, cudaMemcpyHostToDevice));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_dscale, &dscale, sizeof(float), 0, cudaMemcpyHostToDevice));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_nr_cells, &nr_cells, sizeof(unsigned int), 0, cudaMemcpyHostToDevice));
    }

    /* Allocate and fill the task list. */
    if((tasks_cuda = (struct task_cuda *)malloc(sizeof(struct task_cuda) * s->nr_tasks)) == NULL)
        return error(MDCERR_malloc);
    if((cellsorts = (int *)malloc(sizeof(int) * s->nr_tasks)) == NULL)
        return error(MDCERR_malloc);
    for(did = 0 ;did < nr_devices ; did++) {
        if((e->cells_cuda_local[did] = (int *)malloc(sizeof(int) * s->nr_cells)) == NULL)
            return error(MDCERR_malloc);
        e->cells_cuda_nr[did]=0;
        cuda_safe_call(cudaSetDevice(e->devices[did]));
        /* Select the tasks for each device ID. */  
        for(nr_tasks = 0, i = 0 ; i < s->nr_tasks ; i++) {
            
            /* Get local pointers. */
            t = &s->tasks[i];
            tc = &tasks_cuda[nr_tasks];
	    
            /* Skip pairs and self with wrong cid, keep all sorts. */
            if((t->type == task_type_pair && e->s.cells[t->i].GPUID != did  /*t->i % nr_devices != did */) ||
                (t->type == task_type_self && e->s.cells[t->i].GPUID != did /*e->s.cells[t->i].loc[1] < e->s.cdim[1] / e->nr_devices * (did + 1) && e->s.cells[t->i].loc[1] >= e->s.cdim[1] / e->nr_devices * did t->i % e->nr_devices != did*/))
                continue;
            
            /* Copy the data. */
            tc->type = t->type;
            tc->subtype = t->subtype;
            tc->wait = 0;
            tc->flags = t->flags;
            tc->i = t->i;
            tc->j = t->j;
            tc->nr_unlock = 0;
            
            /* Remember which task sorts which cell. */
            if(t->type == task_type_sort) {
                tc->flags = 0;
                cellsorts[ t->i ] = nr_tasks;
            }

            /*Add the cell to list of cells for this GPU if needed*/
            c1 = t->i >= 0; c2 = t->j >= 0;
            for(int i = 0; i < e->cells_cuda_nr[did] ; i++) {
                if(c1 == 0 && c2 == 0) 
                    break;
                /* Check cell is valid */
                if(t->i == e->cells_cuda_local[did][i])
                    c1 = 0;
                if(t->j == e->cells_cuda_local[did][i])
                    c2 = 0;
            }
            if(c1)
                e->cells_cuda_local[did][e->cells_cuda_nr[did]++] = t->i;
            if(c2)
                e->cells_cuda_local[did][e->cells_cuda_nr[did]++] = t->j;	                
            /* Add one task. */
            nr_tasks += 1;
		
        }

        /* Link each pair task to its sorts. */
        for(i = 0 ; i < nr_tasks ; i++) {
            tc = &tasks_cuda[i];
	
            if(tc->type == task_type_pair) {
                ts = &tasks_cuda[ cellsorts[ tc->i ] ];
                ts->flags |= (1 << tc->flags);
                ts->unlock[ ts->nr_unlock ] = i;
                ts->nr_unlock += 1;
                ts = &tasks_cuda[ cellsorts[ tc->j ] ];
                ts->flags |= (1 << tc->flags);
                ts->unlock[ ts->nr_unlock ] = i;
                ts->nr_unlock += 1;
            }
        }
        
        /* Set the waits. */
        for(i = 0 ; i < nr_tasks ; i++)
            for(k = 0 ; k < tasks_cuda[i].nr_unlock ; k++)
                tasks_cuda[ tasks_cuda[i].unlock[k] ].wait += 1;

        /* Remember the number of tasks. */
        e->nrtasks_cuda[did] = nr_tasks;

        std::unordered_map<int, std::vector<int2> > cellpair_map_left, cellpair_map_right;
        for(i = 0; i < nr_tasks; i++) {
            task_cuda& t = tasks_cuda[i];
            if(t.type == task_type_pair) {
                cellpair_map_left[t.i].push_back(make_int2(t.j, t.flags));
                cellpair_map_right[t.j].push_back(make_int2(t.i, t.flags));
            }
        }
        std::vector<int2> cellpair_list_left, cellpair_list_right;
        std::vector<int> cellpair_ind_left, cellpair_ind_right, cellpair_count_left, cellpair_count_right;
        cellpair_list_left.reserve(cellpair_map_left.size());
        cellpair_list_right.reserve(cellpair_map_right.size());
        cellpair_ind_left.reserve(nr_cells);
        cellpair_ind_right.reserve(nr_cells);
        cellpair_count_left.reserve(nr_cells);
        cellpair_count_right.reserve(nr_cells);
        for(i = 0; i < nr_cells; i++) {
            std::vector<int2> cp;
            std::unordered_map<int, std::vector<int2> >::iterator cpitr;
            
            cpitr = cellpair_map_left.find(i);
            cp = cpitr == cellpair_map_left.end() ? std::vector<int2>() : cpitr->second;
            cellpair_ind_left.push_back(cellpair_list_left.size());
            cellpair_count_left.push_back(cp.size());
            cellpair_list_left.insert(cellpair_list_left.end(), cp.begin(), cp.end());

            cpitr = cellpair_map_right.find(i);
            cp = cpitr == cellpair_map_right.end() ? std::vector<int2>() : cpitr->second;
            cellpair_ind_right.push_back(cellpair_list_right.size());
            cellpair_count_right.push_back(cp.size());
            cellpair_list_right.insert(cellpair_list_right.end(), cp.begin(), cp.end());
        }

        cuda_safe_call(cudaMalloc(&dummy[did], sizeof(int2) * cellpair_list_left.size()));
        cuda_safe_call(cudaMemcpy(dummy[did], cellpair_list_left.data(), sizeof(int2) * cellpair_list_left.size(), cudaMemcpyHostToDevice));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_cellpair_list_left, &dummy[did], sizeof(int2*), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMalloc(&dummy[did], sizeof(int2) * cellpair_list_right.size()));
        cuda_safe_call(cudaMemcpy(dummy[did], cellpair_list_right.data(), sizeof(int2) * cellpair_list_right.size(), cudaMemcpyHostToDevice));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_cellpair_list_right, &dummy[did], sizeof(int2*), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMalloc(&dummy[did], sizeof(int) * cellpair_ind_left.size()));
        cuda_safe_call(cudaMemcpy(dummy[did], cellpair_ind_left.data(), sizeof(int) * cellpair_ind_left.size(), cudaMemcpyHostToDevice));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_cellpair_ind_left, &dummy[did], sizeof(int*), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMalloc(&dummy[did], sizeof(int) * cellpair_ind_right.size()));
        cuda_safe_call(cudaMemcpy(dummy[did], cellpair_ind_right.data(), sizeof(int) * cellpair_ind_right.size(), cudaMemcpyHostToDevice));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_cellpair_ind_right, &dummy[did], sizeof(int*), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMalloc(&dummy[did], sizeof(int) * cellpair_count_left.size()));
        cuda_safe_call(cudaMemcpy(dummy[did], cellpair_count_left.data(), sizeof(int) * cellpair_count_left.size(), cudaMemcpyHostToDevice));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_cellpair_count_left, &dummy[did], sizeof(int*), 0, cudaMemcpyHostToDevice));

        cuda_safe_call(cudaMalloc(&dummy[did], sizeof(int) * cellpair_count_right.size()));
        cuda_safe_call(cudaMemcpy(dummy[did], cellpair_count_right.data(), sizeof(int) * cellpair_count_right.size(), cudaMemcpyHostToDevice));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_cellpair_count_right, &dummy[did], sizeof(int*), 0, cudaMemcpyHostToDevice));
            
    }
    
	/* Clean up */
    free(tasks_cuda);
    free(cellsorts);
    
    for(did = 0 ;did < nr_devices ; did++) {
        cuda_safe_call(cudaSetDevice(e->devices[did]));

        /* Allocate the sortlists locally and on the device if needed. */
        cuda_safe_call(cudaMalloc(&e->sortlists_cuda[did], sizeof(unsigned int) * s->nr_parts * 13));
        cuda_safe_call(cudaMemcpyToSymbol(cuda_sortlists, &e->sortlists_cuda[did], sizeof(unsigned int *), 0, cudaMemcpyHostToDevice));
        
	    /* Allocate the cell counts and offsets. */
        if((e->counts_cuda_local[did] = (int *)malloc(sizeof(int) * s->nr_cells)) == NULL ||
           (e->ind_cuda_local[did] = (int *)malloc(sizeof(int) * s->nr_cells)) == NULL)
            return error(MDCERR_malloc);
        cuda_safe_call(cudaMalloc(&e->counts_cuda[did], sizeof(int) * s->nr_cells));
        cuda_safe_call(cudaMalloc(&e->ind_cuda[did], sizeof(int) * s->nr_cells));
    }

    // Allocate boundary conditions
    if(engine_cuda_boundary_conditions_load(e) < 0)
        return error(MDCERR_cuda);
        
    if(engine_cuda_allocate_particles(e) < 0)
        return error(MDCERR_cuda);

    if(engine_cuda_load_pots(e) < 0)
        return error(MDCERR_cuda);

    if(engine_cuda_load_fluxes(e) < 0)
        return error(MDCERR_cuda);
        
    if(engine_cuda_allocate_particle_states(e) < 0)
        return error(MDCERR_cuda);
        
    /* He's done it! */
    return S_OK;
    
}


/**
 * @brief Removes the potentials and cell pairs on the CUDA device.
 *
 * @param e The #engine.
 */
extern "C" HRESULT engine_parts_finalize(struct engine *e) {

    if(engine_cuda_boundary_conditions_finalize(e) < 0)
        return error(MDCERR_cuda);

    if(cuda::engine_cuda_unload_pots(e) < 0)
        return error(MDCERR_cuda);

    if(engine_cuda_finalize_particles(e) < 0)
        return error(MDCERR_cuda);

    if(cuda::engine_cuda_finalize_particle_states(e) < 0)
        return error(MDCERR_cuda);

    if(cuda::engine_cuda_unload_fluxes(e) < 0)
        return error(MDCERR_cuda);

    for(int did = 0; did < e->nr_devices; did++) {

        cuda_safe_call(cudaSetDevice(e->devices[did]));

        e->nrtasks_cuda[did] = 0;

        // Free the sort list, counts and indices

        cuda_safe_call(cudaFree(e->sortlists_cuda[did]));

        cuda_safe_call(cudaFree(e->counts_cuda[did]));

        cuda_safe_call(cudaFree(e->ind_cuda[did]));

    }

    return S_OK;
}

extern "C" HRESULT cuda::engine_cuda_finalize(struct engine *e) {
    if(engine_parts_finalize(e) < 0)
        return error(MDCERR_cuda);

    return S_OK;
}

extern "C" HRESULT cuda::engine_cuda_refresh(struct engine *e) {
    
    if(engine_cuda_finalize(e) < 0)
        return error(MDCERR_cuda);

    if(engine_cuda_load(e) < 0)
        return error(MDCERR_cuda);

    for(int did = 0; did < e->nr_devices; did++) {

        cuda_safe_call(cudaSetDevice(e->devices[did]));

        cuda_safe_call(cudaDeviceSynchronize());

    }

    return S_OK;
}
