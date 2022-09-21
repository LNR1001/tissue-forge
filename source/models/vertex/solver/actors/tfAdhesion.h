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

#ifndef _MODELS_VERTEX_SOLVER_ACTORS_TFADHESION_H_
#define _MODELS_VERTEX_SOLVER_ACTORS_TFADHESION_H_

#include <tf_platform.h>

#include <models/vertex/solver/tfMeshObj.h>


namespace TissueForge::models::vertex { 


    struct Adhesion : MeshObjTypePairActor {

        float lam;

        Adhesion(const float &_lam) {
            lam = _lam;
        }

        HRESULT energy(MeshObj *source, MeshObj *target, float &e);

        HRESULT force(MeshObj *source, MeshObj *target, float *f);
    };

}

#endif // _MODELS_VERTEX_SOLVER_ACTORS_TFADHESION_H_