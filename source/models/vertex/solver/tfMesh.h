/*******************************************************************************
 * This file is part of Tissue Forge.
 * Copyright (c) 2022 T.J. Sego and Tien Comlekoglu
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

#ifndef _MODELS_VERTEX_SOLVER_TFMESH_H_
#define _MODELS_VERTEX_SOLVER_TFMESH_H_

#define TFMESHINV_INCR 100

#include "tfVertex.h"
#include "tfSurface.h"
#include "tfBody.h"
#include "tfMeshQuality.h"

#include <mutex>
#include <set>
#include <vector>
#include <unordered_map>


namespace TissueForge::models::vertex {


    struct MeshRenderer;
    struct MeshSolver;


    class CAPI_EXPORT Mesh { 

        std::vector<Vertex> *vertices;
        size_t nr_vertices;
        std::vector<Surface> *surfaces;
        size_t nr_surfaces;
        std::vector<Body> *bodies;
        size_t nr_bodies;

        std::set<unsigned int> vertexIdsAvail, surfaceIdsAvail, bodyIdsAvail;
        std::unordered_map<int, Vertex*> verticesByPID;
        bool isDirty;
        MeshSolver *_solver = NULL;
        MeshQuality *_quality;
        std::mutex meshLock;

        HRESULT incrementVertices(const size_t &numIncr=TFMESHINV_INCR);
        HRESULT incrementSurfaces(const size_t &numIncr=TFMESHINV_INCR);
        HRESULT incrementBodies(const size_t &numIncr=TFMESHINV_INCR);
        HRESULT allocateVertex(Vertex **obj);
        HRESULT allocateSurface(Surface **obj);
        HRESULT allocateBody(Body **obj);

    public:

        Mesh();

        ~Mesh();

        /** Get a JSON string representation */
        std::string toString();

        /** Test whether this mesh has a mesh quality instance */
        bool hasQuality() const { return _quality; }

        /** Get the mesh quality instance */
        TissueForge::models::vertex::MeshQuality &getQuality() const { return *_quality; }

        /** Set the mesh quality instance */
        HRESULT setQuality(TissueForge::models::vertex::MeshQuality *quality);

        /** Test whether a mesh quality instance is working on the mesh */
        bool qualityWorking() const { return hasQuality() && getQuality().working(); }

        /** Ensure that there are a given number of allocated vertices */
        HRESULT ensureAvailableVertices(const size_t &numAlloc);

        /** Ensure that there are a given number of allocated surfaces */
        HRESULT ensureAvailableSurfaces(const size_t &numAlloc);

        /** Ensure that there are a given number of allocated bodies */
        HRESULT ensureAvailableBodies(const size_t &numAlloc);

        /** Create a vertex */
        HRESULT create(Vertex **obj, const unsigned int &pid);

        /** Create a surface */
        HRESULT create(Surface **obj);

        /** Create a body */
        HRESULT create(Body **obj);

        /** Get the mesh */
        static Mesh *get();

        /** Locks the mesh for thread-safe operations */
        void lock() { this->meshLock.lock(); }
        
        /** Unlocks the mesh for thread-safe operations */
        void unlock() { this->meshLock.unlock(); }

        /**
         * @brief Find a vertex in this mesh
         * 
         * @param pos position to look
         * @param tol distance tolerance
         * @return a vertex within the distance tolerance of the position, otherwise NULL
         */
        Vertex *findVertex(const FVector3 &pos, const FloatP_t &tol = 0.0001);

        /** Get the vertex for a given particle id */
        Vertex *getVertexByPID(const unsigned int &pid) const;

        /** Get the vertex at a location in the list of vertices */
        Vertex *getVertex(const unsigned int &idx);

        /** Get a surface at a location in the list of surfaces */
        Surface *getSurface(const unsigned int &idx);

        /** Get a body at a location in the list of bodies */
        Body *getBody(const unsigned int &idx);

        /** Get the number of vertices */
        unsigned int numVertices() const { return nr_vertices; }

        /** Get the number of surfaces */
        unsigned int numSurfaces() const { return nr_surfaces; }

        /** Get the number of bodies */
        unsigned int numBodies() const { return nr_bodies; }

        /** Get the size of the list of vertices */
        unsigned int sizeVertices() const { return vertices->size(); }

        /** Get the size of the list of surfaces */
        unsigned int sizeSurfaces() const { return surfaces->size(); }

        /** Get the size of the list of bodies */
        unsigned int sizeBodies() const { return bodies->size(); }

        /** Validate state of the mesh */
        bool validate();

        /** Manually notify that the mesh has been changed */
        HRESULT makeDirty();

        /** Check whether two vertices are connected */
        bool connected(const Vertex *v1, const Vertex *v2) const;

        /** Check whether two surfaces are connected */
        bool connected(const Surface *s1, const Surface *s2) const;

        /** Check whether two bodies are connected */
        bool connected(const Body *b1, const Body *b2) const;

        // Mesh editing

        /** Remove a vertex from the mesh; all connected surfaces and bodies are also removed */
        HRESULT remove(Vertex *v);

        /** Remove a surface from the mesh; all connected bodies are also removed */
        HRESULT remove(Surface *s);

        /** Remove a body from the mesh */
        HRESULT remove(Body *b);

        friend MeshRenderer;
        friend MeshSolver;

    };

};

#endif // _MODELS_VERTEX_SOLVER_TFMESH_H_