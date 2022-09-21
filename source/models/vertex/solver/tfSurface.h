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

#ifndef _MODELS_VERTEX_SOLVER_TFSURFACE_H_
#define _MODELS_VERTEX_SOLVER_TFSURFACE_H_

#include <tf_port.h>

#include <state/tfStateVector.h>
#include <rendering/tfStyle.h>

#include "tf_mesh.h"

#include <io/tfThreeDFFaceData.h>

#include <tuple>


namespace TissueForge::models::vertex { 


    class Vertex;
    class Body;
    class Structure;
    class Mesh;

    struct SurfaceType;


    /**
     * @brief The mesh surface is an area-enclosed object of implicit mesh edges defined by mesh vertices. 
     * 
     * The mesh surface consists of at least three mesh vertices. 
     * 
     * The mesh surface is always flat. 
     * 
     * The mesh surface can have a state vector, which represents a uniform amount of substance 
     * attached to the surface. 
     * 
     */
    class CAPI_EXPORT Surface : public MeshObj {

        /** Connected body, if any, where the surface normal is outward-facing */
        Body *b1;
        
        /** Connected body, if any, where the surface normal is inward-facing */
        Body *b2;

        std::vector<Vertex*> vertices;

        FVector3 normal;

        FVector3 centroid;

        FVector3 velocity;

        FloatP_t area;

        /** Volume contributed by this surface to its child bodies */
        FloatP_t _volumeContr;

    public:

        unsigned int typeId;

        state::StateVector *species;

        rendering::Style *style;

        Surface();

        /** Construct a surface from a set of vertices */
        Surface(std::vector<Vertex*> _vertices);

        /** Construct a surface from a face */
        Surface(io::ThreeDFFaceData *face);

        MeshObj::Type objType() { return MeshObj::Type::SURFACE; }

        std::vector<MeshObj*> parents() { return TissueForge::models::vertex::vectorToBase(vertices); }

        std::vector<MeshObj*> children();

        HRESULT addChild(MeshObj *obj);

        HRESULT addParent(MeshObj *obj);

        HRESULT removeChild(MeshObj *obj);

        HRESULT removeParent(MeshObj *obj);

        bool validate();

        HRESULT refreshBodies();

        SurfaceType *type();

        HRESULT insert(Vertex *toInsert, Vertex *v1, Vertex *v2);

        std::vector<Structure*> getStructures();

        std::vector<Body*> getBodies();

        std::vector<Vertex*> getVertices() { return vertices; }

        Vertex *findVertex(const FVector3 &dir);
        Body *findBody(const FVector3 &dir);

        std::tuple<Vertex*, Vertex*> neighborVertices(Vertex *v);

        std::vector<Surface*> neighborSurfaces();

        std::vector<unsigned int> contiguousEdgeLabels(Surface *other);

        unsigned int numSharedContiguousEdges(Surface *other);

        FVector3 getNormal() { return normal; }

        FVector3 getCentroid() { return centroid; }

        FVector3 getVelocity() { return velocity; }

        FloatP_t getArea() { return area; }

        FloatP_t volumeSense(Body *body);
        FloatP_t getVolumeContr(Body *body) { return _volumeContr * volumeSense(body); }

        FloatP_t getVertexArea(Vertex *v);

        FVector3 triangleNormal(const unsigned int &idx);

        HRESULT positionChanged();

        /** Sew two surfaces 
         * 
         * All vertices are merged that are a distance apart less than a distance criterion. 
         * 
         * The distance criterion is the square root of the average of the two surface areas, multiplied by a coefficient. 
        */
        static HRESULT sew(Surface *s1, Surface *s2, const FloatP_t &distCf=0.01);


        friend Body;
        friend Mesh;

    };


    struct CAPI_EXPORT SurfaceType : MeshObjType {

        rendering::Style *style;

        SurfaceType() : MeshObjType() {
            style = NULL;
        }

        MeshObj::Type objType() { return MeshObj::Type::SURFACE; }

        /** Construct a surface of this type from a set of vertices */
        Surface *operator() (std::vector<Vertex*> _vertices);

        /** Construct a surface of this type from a set of positions */
        Surface *operator() (const std::vector<FVector3> &_positions);

        /** Construct a surface of this type from a face */
        Surface *operator() (io::ThreeDFFaceData *face);

        /** Construct a polygon with n vertices circumscribed on a circle */
        Surface *nPolygon(const unsigned int &n, const FVector3 &center, const FloatP_t &radius, const FVector3 &ax1, const FVector3 &ax2);

    };

}

#endif // _MODELS_VERTEX_SOLVER_TFSURFACE_H_