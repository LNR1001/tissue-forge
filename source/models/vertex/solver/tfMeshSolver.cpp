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

// todo: parallelize execution

#include "tfMeshSolver.h"

#include "tfMeshObj.h"
#include "tfMeshRenderer.h"

#include <tfEngine.h>
#include <tf_util.h>
#include <tfLogger.h>
#include <tfTaskScheduler.h>


#define TF_MESHSOLVER_CHECKINIT { if(!_solver) return E_FAIL; }


static std::mutex _meshEngineLock;


using namespace TissueForge;
using namespace TissueForge::models::vertex;


HRESULT TissueForge::models::vertex::VertexForce(Vertex *v, FloatP_t *f) {
    // Surfaces
    for(auto &s : v->getSurfaces()) {
        for(auto &a : s->type()->actors) 
            a->force(s, v, f);
        
        for(auto &a : s->actors) 
            a->force(s, v, f);
    }

    // Bodies
    for(auto &b : v->getBodies()) {
        for(auto &a : b->type()->actors) 
            a->force(b, v, f);

        for(auto &a : b->actors) 
            a->force(b, v, f);
    }

    // Structures
    for(auto &st : v->getStructures()) {
        for(auto &a : st->type()->actors) 
            a->force(st, v, f);

        for(auto &a : st->actors) 
            a->force(st, v, f);
    }

    return S_OK;
}


static MeshSolver *_solver = NULL;


HRESULT MeshSolver::init() {
    if(_solver != NULL) 
        return S_OK;

    _solver = new MeshSolver();
    _solver->_bufferSize = 1;
    _solver->_forces = (FloatP_t*)malloc(3 * sizeof(FloatP_t));
    _solver->registerEngine();

    // Launches and registers renderer
    MeshRenderer::get();

    return S_OK;
}

MeshSolver *MeshSolver::get() { 
    if(_solver == NULL) 
        if(init() != S_OK) 
            return NULL;
    return _solver;
}

HRESULT MeshSolver::compact() { 
    TF_MESHSOLVER_CHECKINIT

    if(_solver->_bufferSize > 1) {
        free(_forces);
        _bufferSize = 1;
        _forces = (FloatP_t*)malloc(3 * sizeof(FloatP_t));
    }

    return S_OK;
}

HRESULT MeshSolver::engineLock() {
    TF_MESHSOLVER_CHECKINIT

    _solver->_engineLock.lock();
    return S_OK;
}

HRESULT MeshSolver::engineUnlock() {
    TF_MESHSOLVER_CHECKINIT

    _solver->_engineLock.unlock();
    return S_OK;
}

Mesh *MeshSolver::newMesh() {
    Mesh *mesh = new Mesh();
    if(loadMesh(mesh) != S_OK) 
        return NULL;
    return mesh;
}

HRESULT MeshSolver::loadMesh(Mesh *mesh) {
    for(auto &m : meshes) 
        if(m == mesh) 
            return E_FAIL;
    meshes.push_back(mesh);
    mesh->_solver = this;
    mesh->isDirty = true;
    _isDirty = true;
    return S_OK;
}

HRESULT MeshSolver::unloadMesh(Mesh *mesh) {
    for(auto itr = meshes.begin(); itr != meshes.end(); itr++) {
        if(*itr == mesh) {
            meshes.erase(itr);
            _isDirty = true;
            (*itr)->_solver = NULL;
            return S_OK;
        }
    }
    return E_FAIL;
}

HRESULT MeshSolver::registerType(BodyType *_type) {
    if(!_type || _type->id >= 0) 
        return E_FAIL;
    
    _type->id = _bodyTypes.size();
    _bodyTypes.push_back(_type);

    return S_OK;
}

HRESULT MeshSolver::registerType(SurfaceType *_type) {
    if(!_type || _type->id >= 0) 
        return E_FAIL;

    _type->id = _surfaceTypes.size();
    if(!_type->style) {
        auto colors = color3Names();
        auto c = colors[(_surfaceTypes.size() - 1) % colors.size()];
        _type->style = new rendering::Style(c);
    }
    _surfaceTypes.push_back(_type);

    return S_OK;
}

StructureType *MeshSolver::getStructureType(const unsigned int &typeId) {
    if(typeId >= _structureTypes.size()) 
        return NULL;
    return _structureTypes[typeId];
}

BodyType *MeshSolver::getBodyType(const unsigned int &typeId) {
    if(typeId >= _bodyTypes.size()) 
        return NULL;
    return _bodyTypes[typeId];
}

SurfaceType *MeshSolver::getSurfaceType(const unsigned int &typeId) {
    if(typeId >= _surfaceTypes.size()) 
        return NULL;
    return _surfaceTypes[typeId];
}

template <typename T> 
void Mesh_actRecursive(MeshObj *vertex, T *source, FloatP_t *f) {
    for(auto &a : source->type()->actors) 
        a->force(source, vertex, f);
    for(auto &c : source->children()) 
        Mesh_actRecursive(vertex, (T*)c, f);
}

HRESULT MeshSolver::positionChanged() {

    unsigned int i;
    _surfaceVertices = 0;
    _totalVertices = 0;

    for(auto &m : meshes) {
        for(i = 0; i < m->sizeVertices(); i++) {
            Vertex *v = m->getVertex(i);
            if(v) 
                v->positionChanged();
        }
        _totalVertices += m->numVertices();

        for(i = 0; i < m->sizeSurfaces(); i++) {
            Surface *s = m->getSurface(i);
            if(s) {
                s->positionChanged();
                _surfaceVertices += s->parents().size();
            }
        }

        for(i = 0; i < m->sizeBodies(); i++) {
            Body *b = m->getBody(i);
            if(b) 
                b->positionChanged();
        }
        
        for(i = 0; i < m->sizeVertices(); i++) {
            Vertex *v = m->getVertex(i);
            if(v) 
                v->updateProperties();
        }

        m->isDirty = false;
    }

    _isDirty = false;

    return S_OK;
}

HRESULT MeshSolver::update(const bool &_force) {
    if(!isDirty() || _force) 
        return S_OK;
    
    positionChanged();
    return S_OK;
}

HRESULT MeshSolver::preStepStart() { 
    TF_MESHSOLVER_CHECKINIT

    MeshLogger::clear();

    unsigned int i, j, k;
    Mesh *m;
    Vertex *v;
    Surface *s;
    Body *b;

    _surfaceVertices = 0;
    _totalVertices = 0;

    for(i = 0; i < meshes.size(); i++) {
        j = meshes[i]->sizeVertices();
        _totalVertices += j;
    }

    if(_totalVertices > _bufferSize) {
        free(_solver->_forces);
        _bufferSize = _totalVertices;
        _solver->_forces = (FloatP_t*)malloc(3 * sizeof(FloatP_t) * _bufferSize);
    }
    memset(_solver->_forces, 0.f, 3 * sizeof(FloatP_t) * _bufferSize);

    static int stride = ThreadPool::size();
    std::vector<int> local_surfaceVertices(stride, 0);
    for(i = 0, j = 0; i < meshes.size(); i++) { 
        m = meshes[i];

        std::vector<Vertex*> &m_vertices = m->vertices;
        FloatP_t *_forces_j = &_forces[j * 3];
        auto func = [&m_vertices, &local_surfaceVertices, &_forces_j](int tid) -> void {
            int surfaceVertices_sum = 0;
            for(int k = tid; k < m_vertices.size(); ) {
                Vertex *v = m_vertices[k];
                
                if(v) { 
                    surfaceVertices_sum += v->children().size();

                    VertexForce(v, &_forces_j[k * 3]);
                }

                k += stride;
            }
            local_surfaceVertices[tid] = surfaceVertices_sum;
        };
        parallel_for(stride, func);

        for(int k = 0; k < stride; k++) 
            _surfaceVertices += local_surfaceVertices[k];
        
        j += m->vertices.size();
    }

    return S_OK;
}

HRESULT MeshSolver::preStepJoin() {
    unsigned int i, j;
    FloatP_t *buff;
    Mesh *m;
    Particle *p;

    for(i = 0, j = 0; i < meshes.size(); i++) { 
        m = meshes[i];

        FloatP_t *_forces_j = &_forces[j * 3];
        std::vector<Vertex*> &m_vertices = m->vertices;
        auto func = [&m_vertices, &_forces_j](int k) -> void {
            Vertex *v = m_vertices[k];
            if(!v) {
                return;
            }

            Particle *p = v->particle()->part();
            FloatP_t *buff = &_forces_j[k * 3];
            p->f[0] += buff[0];
            p->f[1] += buff[1];
            p->f[2] += buff[2];
        };
        parallel_for(m_vertices.size(), func);
        j += m->vertices.size();
    }

    return S_OK;
}

HRESULT MeshSolver::postStepStart() {
    setDirty(true);

    if(positionChanged() != S_OK) 
        return E_FAIL;

    for(auto &m : meshes) 
        if(m->hasQuality()) 
            m->getQuality().doQuality();

    return S_OK;
}

HRESULT MeshSolver::postStepJoin() {
    return S_OK;
}

HRESULT MeshSolver::log(Mesh *mesh, const MeshLogEventType &type, const std::vector<int> &objIDs, const std::vector<MeshObj::Type> &objTypes, const std::string &name) {
    int meshID = -1;
    for(int i = 0; i < meshes.size(); i++) 
        if(meshes[i] == mesh) {
            meshID = i;
            break;
        }

    if(meshID < 0) {
        TF_Log(LOG_ERROR) << "Mesh not in solved";
        return E_FAIL;
    }

    MeshLogEvent event;
    event.name = name;
    event.meshID = meshID;
    event.type = type;
    event.objIDs = objIDs;
    event.objTypes = objTypes;
    return MeshLogger::log(event);
}

bool MeshSolver::isDirty() {
    if(_isDirty) 
        return true;
    bool result = false;
    for(auto &m : meshes) 
        result |= m->isDirty;
    return result;
}

HRESULT MeshSolver::setDirty(const bool &_dirty) {
    _isDirty = _dirty;
    for(auto &m : meshes) 
        m->isDirty = _dirty;
    return S_OK;
}
