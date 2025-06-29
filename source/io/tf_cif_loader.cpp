#include "tf_cif_loader.h"
#include <gemmi/cif.hpp>
#include <string>

namespace TissueForge {
namespace io {

CPPAPI_FUNC(std::unordered_map<std::string,
    std::vector<TissueForge::types::TVector3<float>>>)
loadCifParticles(const std::string& cifData) {
    
    std::unordered_map<std::string, std::vector<TissueForge::types::TVector3<float>>> result;

    try {
        // 1) parse the CIF
        gemmi::cif::Document doc = gemmi::cif::read_string(cifData);
        gemmi::cif::Block&    block = doc.sole_block();

        // 2) *init* the _atom_site loop and ask for exactly the four tags we need
        //    init_mmcif_loop will prepend "_atom_site." automatically
        gemmi::cif::Loop& loop = block.init_mmcif_loop(
            "_atom_site",
            { "type_symbol", "Cartn_x", "Cartn_y", "Cartn_z" }
        );

        // 3) iterate
        size_t n = loop.length();
        for (size_t i = 0; i < n; ++i) {
            std::string typ = loop.val(i, 0);
            float x = std::stof(loop.val(i, 1));
            float y = std::stof(loop.val(i, 2));
            float z = std::stof(loop.val(i, 3));
            result[typ].emplace_back(x, y, z);
        }
    } catch (...) {
        // if anything goes wrong (no atom_site loop, bad numbers, …), just
        // return whatever we managed to read
    }
    return result;
}

} // namespace io
} // namespace TissueForge
