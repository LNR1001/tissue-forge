#pragma once

#include <string>
#include <iostream>
#include <iomanip>
#include <gemmi/cif.hpp>
#include <gemmi/mmcif.hpp>

namespace tf {

inline gemmi::Structure read_structure_file(const std::string& filepath) {
    gemmi::cif::Document doc = gemmi::cif::read_file(filepath);
    return gemmi::make_structure(std::move(doc));
}

// Logs structure details to the console
// inline void log_structure(const gemmi::Structure& structure) {
//     std::cout << "[INFO] Structure name: " << structure.name << std::endl;
//     std::cout << "[INFO] Number of models: " << structure.models.size() << std::endl;

//     for (const auto& model : structure.models) {
//         std::cout << "\n🧬 Model: " << model.name << std::endl;
//         for (const auto& chain : model.chains) {
//             std::cout << "  🔗 Chain " << chain.name
//                       << " with " << chain.residues.size() << " residues\n";
//             for (const auto& res : chain.residues) {
//                 std::cout << "    🧱 Residue: " << res.name << " " << res.seqid.str() << "\n";
//                 for (const auto& atom : res.atoms) {
//                     std::cout << std::fixed << std::setprecision(2)
//                               << "      🔬 Atom: " << atom.name
//                               << " at (" << atom.pos.x << ", "
//                               << atom.pos.y << ", " << atom.pos.z << ")\n";
//                 }
//             }
//         }
//     }

//     if (structure.resolution != 0.0) {
//         std::cout << "\n🔍 Resolution: " << structure.resolution << " Å\n";
//     }
// }

}
