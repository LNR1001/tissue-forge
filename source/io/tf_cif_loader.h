/*******************************************************************************
 * This file is part of Tissue Forge.
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
 ******************************************************************************/

#ifndef _SOURCE_IO_TF_CIF_LOADER_H_
#define _SOURCE_IO_TF_CIF_LOADER_H_

#include <tf_port.h>
#include <types/tf_types.h>

#include <unordered_map>
#include <vector>

namespace TissueForge::io {

// --- simple structs for returning atoms + bonds ---
struct AtomLite {
    std::string element;                  // _atom_site.type_symbol
    types::TVector3<float> pos;           // Cartn_x, Cartn_y, Cartn_z
    std::string residue;                  // _atom_site.label_comp_id
    std::string chain;                    // _atom_site.label_asym_id
    int seq_id = -1;                      // _atom_site.label_seq_id (or -1)
    std::string atom_name;                // _atom_site.label_atom_id (e.g., CA, N)
};

struct BondLite { int a = -1; int b = -1; };   // indices into atoms[]

struct CifStructureLite {
    std::vector<AtomLite> atoms;
    std::vector<BondLite> bonds;
};

CPPAPI_FUNC(size_t) cifAtomsSize(const CifStructureLite& s);
CPPAPI_FUNC(const AtomLite&) cifAtomAt(const CifStructureLite& s, size_t i);
CPPAPI_FUNC(size_t) cifBondsSize(const CifStructureLite& s);
CPPAPI_FUNC(const BondLite&) cifBondAt(const CifStructureLite& s, size_t i);

// NEW simple API (atoms + bonds). keeps your old API intact.
CPPAPI_FUNC(CifStructureLite) loadCifAtomsAndBonds(const std::string& cifData);
    
/**
 * @brief Parse CIF data and group atom coordinates by type
 *
 * @param cifData CIF file contents
 * @return Mapping of atom type to coordinates
 */
CPPAPI_FUNC(std::unordered_map<std::string, std::vector<TissueForge::types::TVector3<float>>>)
loadCifParticles(const std::string& cifData);

} // namespace TissueForge::io

#endif // _SOURCE_IO_TF_CIF_LOADER_H_
