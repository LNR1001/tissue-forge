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

#ifndef _MODELS_VERTEX_SOLVER_TFSTRUCTURE_H_
#define _MODELS_VERTEX_SOLVER_TFSTRUCTURE_H_

#include <tf_port.h>

#include "tf_mesh.h"


namespace TissueForge::models::vertex { 


    class Vertex;
    class Surface;
    class Body;

    struct StructureType;


    class CAPI_EXPORT Structure : public MeshObj {

        std::vector<Structure*> structures_parent;
        std::vector<Structure*> structures_child;
        std::vector<Body*> bodies;

    public:

        /** Id of the type*/
        unsigned int typeId;

        Structure() : MeshObj() {};

        /** Get the mesh object type */
        MeshObj::Type objType() const override { return MeshObj::Type::STRUCTURE; }

        /** Get the parents of the object */
        std::vector<MeshObj*> parents() const override;

        /** Get the children of the object */
        std::vector<MeshObj*> children() const override { return TissueForge::models::vertex::vectorToBase(structures_child); }

        /** Add a child object */
        HRESULT addChild(MeshObj *obj) override;

        /** Add a parent object */
        HRESULT addParent(MeshObj *obj) override;

        /** Remove a child object */
        HRESULT removeChild(MeshObj *obj) override;

        /** Remove a parent object */
        HRESULT removeParent(MeshObj *obj) override;

        /**
         * Destroy the structure. 
         * 
         * If the structure is in a mesh, then it is removed from the mesh. 
        */
        HRESULT destroy() override;

        /** Validate the structure */
        bool validate() override { return true; }

        /** Get the structure type */
        StructureType *type() const;

        /** Become a different type */
        HRESULT become(StructureType *stype);

        /** Get the structures that this structure defines */
        std::vector<Structure*> getStructures() const { return structures_parent; }

        /** Get the bodies that define the structure */
        std::vector<Body*> getBodies() const;

        /** Get the surfaces that define the structure */
        std::vector<Surface*> getSurfaces() const;

        /** Get the vertices that define the structure */
        std::vector<Vertex*> getVertices() const;

    };


    /**
     * @brief Mesh structure type
     * 
     * Can be used as a factory to create mesh structure instances with 
     * processes and properties that correspond to the type. 
     */
    struct CAPI_EXPORT StructureType : MeshObjType {

        /** Get the mesh object type */
        MeshObj::Type objType() const override { return MeshObj::Type::STRUCTURE; }
        
    };

}

#endif // _MODELS_VERTEX_SOLVER_TFSTRUCTURE_H_