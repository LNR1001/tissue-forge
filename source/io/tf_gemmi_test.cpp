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

 #include "tf_gemmi_helper.h"
 #include <iostream>
 #include <iomanip>
 #include <gemmi/cif.hpp>
 #include <gemmi/mmcif.hpp>
 
 namespace TissueForge::io {

// void parseCifWithGemmi(const std::string& cifData) {
//     std::cout << "[DEBUG] Entering parseCifWithGemmi()\n";

//     try {
//     gemmi::cif::Document doc = gemmi::cif::read_string(cifData);
//         std::cout << "[DEBUG] Successfully parsed document\n";

//         auto block = doc.sole_block();
//         std::cout << "[DEBUG] Got sole block: " << block.name << "\n";

//         // Comment this line temporarily
//         gemmi::Structure structure = gemmi::make_structure_from_block(block);
// //         tf::log_structure(structure);  // ✅ Log details using helper

//         std::cout << "[DEBUG] Finished parseCifWithGemmi()\n";
//     } catch (const std::exception& e) {
//         std::cerr << "parseCifWithGemmi failed: " << e.what() << std::endl;
//     }
//     std::cout << "[DEBUG] Exiting parseCifWithGemmi()\n";
// }

void parseCifWithGemmi(const std::string& cifData) {
    std::cout << "[DEBUG] Entering parseCifWithGemmi()\n";

    try {
        gemmi::cif::Document doc = gemmi::cif::read_string(cifData);
        std::cout << "[DEBUG] Successfully parsed document\n";

        gemmi::cif::Block& block = doc.sole_block();
        std::cout << "[DEBUG] Got sole block: " << block.name << "\n";

        for (const gemmi::cif::Item& item : block.items) {
            if (item.type == gemmi::cif::ItemType::Loop) {
                const gemmi::cif::Loop& loop = item.loop;
                std::cout << "[INFO] Loop with tags:\n";
                for (const std::string& tag : loop.tags)
                    std::cout << "  🔁 " << tag << "\n";

                // Optional: print first few rows of the loop
                size_t nRows = std::min<size_t>(5, loop.length());
                for (size_t i = 0; i < nRows; ++i) {
                    std::cout << "  Row " << i << ": ";
                    for (size_t j = 0; j < loop.width(); ++j)
                        std::cout << loop.val(i, j) << " ";
                    std::cout << "\n";
                }
            }
        }

        std::cout << "[DEBUG] Finished parseCifWithGemmi()\n";
    } catch (const std::exception& e) {
        std::cerr << "❌ parseCifWithGemmi failed: " << e.what() << std::endl;
    }

    std::cout << "[DEBUG] Exiting parseCifWithGemmi()\n";
}


} // namespace TissueForge::io

 