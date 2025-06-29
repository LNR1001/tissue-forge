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
