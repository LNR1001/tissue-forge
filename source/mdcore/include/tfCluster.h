/*******************************************************************************
 * This file is part of mdcore.
 * Copyright (c) 2022 T.J. Sego
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

/**
 * @file tfCluster.h
 * 
 */

#ifndef _MDCORE_INCLUDE_TFCLUSTER_H_
#define _MDCORE_INCLUDE_TFCLUSTER_H_

#include "tfParticle.h"


namespace TissueForge {


    /**
     * @brief The cluster analogue to :class:`Particle`. 
     * 
     */
    struct CAPI_EXPORT Cluster : Particle {};

    struct ClusterParticleHandle;

    /**
     * @brief The cluster analogue to :class:`ParticleType`. 
     * 
     */
    struct CAPI_EXPORT ClusterParticleType : ParticleType {

        ClusterParticleType(const bool &noReg=false);

        /**
         * @brief Tests where this cluster has a particle type
         * 
         * @param type type to test
         * @return true if this cluster has the type
         */
        bool hasType(const ParticleType *type);

        /**
         * @brief Registers a type with the engine. 
         * 
         * Note that this does not occur automatically for basic usage, 
         * to allow type-specific operations independently of the engine. 
         * 
         * Also registers all unregistered constituent types. 
         * 
         * @return HRESULT 
         */
        HRESULT registerType();

        /**
         * @brief Get the type engine instance
         * 
         * @return ClusterParticleType* 
         */
        virtual ClusterParticleType *get();

    };

    /**
     * @brief The cluster analogue to :class:`ParticleHandle`. 
     * 
     * These are special in that they can create particles of their 
     * constituent particle types, much like a :class:`ParticleType`. 
     * 
     */
    struct CAPI_EXPORT ClusterParticleHandle : ParticleHandle {
        ClusterParticleHandle();
        ClusterParticleHandle(const int &id, const int &typeId);

        /**
         * @brief Gets the actual cluster of this handle. 
         * 
         * @return Particle* 
         */
        Cluster *cluster();

        /**
         * @brief Constituent particle constructor. 
         * 
         * The created particle will belong to this cluster. 
         * 
         * Automatically updates when running on a CUDA device. 
         * 
         * @param partType type of particle to create
         * @param position position of new particle, optional
         * @param velocity velocity of new particle, optional
         * @return ParticleHandle* 
         */
        ParticleHandle *operator()(
            ParticleType *partType, 
            FVector3 *position=NULL, 
            FVector3 *velocity=NULL
        );
        
        /**
         * @brief Constituent particle constructor. 
         * 
         * The created particle will belong to this cluster. 
         * 
         * Automatically updates when running on a CUDA device. 
         * 
         * @param partType type of particle to create
         * @param str JSON string
         * @return ParticleHandle* 
         */
        ParticleHandle *operator()(ParticleType *partType, const std::string &str);

        ParticleHandle* fission(
            FVector3 *axis=NULL, 
            bool *random=NULL, 
            FPTYPE *time=NULL, 
            FVector3 *normal=NULL, 
            FVector3 *point=NULL
        );

        /**
         * @brief Split the cluster. 
         * 
         * @param axis axis of split, optional
         * @param random divide by randomly and evenly allocating constituent particles, optional
         * @param time time at which to implement the split; currently not supported
         * @param normal normal vector of cleavage plane, optional
         * @param point point on cleavage plane, optional
         * @return ParticleHandle* 
         */
        ParticleHandle* split(
            FVector3 *axis=NULL, 
            bool *random=NULL, 
            FPTYPE *time=NULL, 
            FVector3 *normal=NULL, 
            FVector3 *point=NULL
        );

        /**
         * @brief Get all particles of this cluster. 
         * 
         * @return ParticleList* 
         */
        ParticleList *items();
        
        FPTYPE getRadiusOfGyration();
        FVector3 getCenterOfMass();
        FVector3 getCentroid();
        FMatrix3 getMomentOfInertia();
    };

    /**
     * adds an existing particle to the cluster.
     */
    CAPI_FUNC(int) Cluster_AddParticle(struct Cluster *cluster, struct Particle *part);


    /**
     * Computes the aggregate quanties such as total mass, position, acceleration, etc...
     * from the contained particles. 
     */
    CAPI_FUNC(int) Cluster_ComputeAggregateQuantities(struct Cluster *cluster);

    /**
     * creates a new particle, and adds it to the cluster.
     */
    CAPI_FUNC(Particle*) Cluster_CreateParticle(
        Cluster *cluster,
        ParticleType* particleType, 
        FVector3 *position=NULL, 
        FVector3 *velocity=NULL
    );

    /**
     * @brief Get a registered cluster type by type name
     * 
     * @param name name of cluster type
     * @return ClusterParticleType* 
     */
    CAPI_FUNC(ClusterParticleType*) ClusterParticleType_FindFromName(const char* name);

    /**
     * internal function to initalize the particle and particle types
     */
    HRESULT _Cluster_init();


    /**
     * @brief Create a cluster from a JSON string representation
     * 
     * @param str 
     * @return Cluster* 
     */
    Cluster *Cluster_fromString(const std::string &str);

    /**
     * @brief Create a cluster type from a JSON string representation
     * 
     * @param str 
     * @return ClusterParticleType* 
     */
    ClusterParticleType *ClusterParticleType_fromString(const std::string &str);

};

#endif // _MDCORE_INCLUDE_TFCLUSTER_H_