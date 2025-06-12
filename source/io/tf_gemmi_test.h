/*******************************************************************************
 * This file is part of Tissue Forge.
 * Copyright (c) 2022-2024 ...
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

 #ifndef _SOURCE_IO_TFGEMMI_H_
 #define _SOURCE_IO_TFGEMMI_H_
 
 #include <string>
 #include "TissueForge_private.h"  // If you need TF macros/types
 
 namespace TissueForge::io {
 
 /**
  * @brief Parse CIF data using Gemmi and optionally load it into Tissue Forge structures
  *
  * @param cifData The CIF data (in plain text form)
  */
 CPPAPI_FUNC(void) parseCifWithGemmi(const std::string& cifData);
 
 } // namespace TissueForge::io
 
 #endif // _SOURCE_IO_TFGEMMI_H_
 