#include "tf_cif_loader.h"
#include <gemmi/cif.hpp>
#include <iostream>
#include <string>
#include <types/tf_types.h>

namespace TissueForge {
namespace io {

using types::TVector3;

CPPAPI_FUNC(std::unordered_map<std::string, std::vector<TVector3<float>>>) loadCifParticles(const std::string& cifData) { 
    
    std::unordered_map<std::string, std::vector<TVector3<float>>> result;

  try {
    // 1) parse the CIF
    gemmi::cif::Document doc = gemmi::cif::read_string(cifData);
    gemmi::cif::Block& block = doc.sole_block();

    // 2) find the mmCIF loop whose tags start with "_atom_site."
    //    and _must_ contain type_symbol, Cartn_x, Cartn_y, Cartn_z
    auto table = block.find("_atom_site.",
                            { "type_symbol",
                              "Cartn_x",
                              "Cartn_y",
                              "Cartn_z" }
                           );
    if (! table.ok()) {
      throw std::runtime_error(
        "No _atom_site loop with type_symbol/Cartn_x/Cartn_y/Cartn_z"
      );
    }

    // 3) iterate each row in that table
    for (auto row : table) {
      std::string  type = row.str(0);           // first column
      float        x    = std::stof(row.at(1)); // Cartn_x
      float        y    = std::stof(row.at(2)); // Cartn_y
      float        z    = std::stof(row.at(3)); // Cartn_z

      result[type].emplace_back(x, y, z);
    }
  }
  catch (const std::exception& e) {
    std::cerr << "loadCifParticles threw: " << e.what() << "\n";
  }
  catch (...) {
    std::cerr << "loadCifParticles threw unknown exception\n";
  }

  return result;
}

}  // namespace io
}  // namespace TissueForge

