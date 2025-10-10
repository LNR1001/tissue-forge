#include "tf_cif_loader.h"
#include <gemmi/cif.hpp>
#include <iostream>
#include <string>
#include <vector>
#include <cmath>
#include <types/tf_types.h>

namespace TissueForge {
namespace io {

using types::TVector3;

CPPAPI_FUNC(size_t) cifAtomsSize(const CifStructureLite& s) { return s.atoms.size(); }
CPPAPI_FUNC(const AtomLite&) cifAtomAt(const CifStructureLite& s, size_t i) { return s.atoms.at(i); }
CPPAPI_FUNC(size_t) cifBondsSize(const CifStructureLite& s) { return s.bonds.size(); }
CPPAPI_FUNC(const BondLite&) cifBondAt(const CifStructureLite& s, size_t i) { return s.bonds.at(i); }

// ---------------- your existing atoms-only API (unchanged) ----------------

CPPAPI_FUNC(std::unordered_map<std::string, std::vector<TVector3<float>>>)
loadCifParticles(const std::string& cifData) {
    std::unordered_map<std::string, std::vector<TVector3<float>>> result;

    try {
        gemmi::cif::Document doc = gemmi::cif::read_string(cifData);
        gemmi::cif::Block& block = doc.sole_block();

        auto table = block.find("_atom_site.",
                                { "type_symbol", "Cartn_x", "Cartn_y", "Cartn_z" });
        if (!table.ok()) {
            throw std::runtime_error(
                "No _atom_site loop with type_symbol/Cartn_x/Cartn_y/Cartn_z"
            );
        }

        for (auto row : table) {
            std::string  type = row.str(0);
            float        x    = std::stof(row.at(1));
            float        y    = std::stof(row.at(2));
            float        z    = std::stof(row.at(3));
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

// ---------------- NEW simple API: atoms + bonds (trimmed) ----------------
CPPAPI_FUNC(CifStructureLite)
loadCifAtomsAndBonds(const std::string& cifData) {
    CifStructureLite out;

    // add a bond safely (no self-edges, no duplicates)
    auto add_bond = [&](int i, int j){
        if (i < 0 || j < 0 || i == j) return;
        if (j < i) std::swap(i, j);                  // canonicalize order
        for (const auto &b : out.bonds)              // de-duplicate
            if (b.a == i && b.b == j) return;
        out.bonds.push_back({i, j});
    };

    // linear scan to find an atom by (chain, seq_id, atom_name)
    auto findAtomIndex = [&](const std::string& chain, int seq_id, const std::string& name)->int {
        for (int i = 0; i < (int)out.atoms.size(); ++i) {
            const auto& a = out.atoms[i];
            if (a.chain == chain && a.seq_id == seq_id && a.atom_name == name) return i;
        }
        return -1;
    };

    try {
        gemmi::cif::Document doc = gemmi::cif::read_string(cifData);
        gemmi::cif::Block& block = doc.sole_block();

        // ---- ATOMS: read element, coords, residue/chain/seq, atom name ----
        auto atom_tbl = block.find("_atom_site.", {
            "type_symbol", "Cartn_x", "Cartn_y", "Cartn_z",
            "label_comp_id", "label_asym_id", "label_seq_id",
            "label_atom_id"
        });
        if (!atom_tbl.ok())
            throw std::runtime_error("Missing required _atom_site fields");

        out.atoms.reserve(atom_tbl.length());
        for (auto row : atom_tbl) {
            AtomLite a;
            a.element   = row.str(0);
            a.pos       = TVector3<float>{ std::stof(row.at(1)),
                                           std::stof(row.at(2)),
                                           std::stof(row.at(3)) };
            a.residue   = row.str(4);                     // label_comp_id
            a.chain     = row.str(5);                     // label_asym_id
            const std::string seq_s = row.str(6);         // label_seq_id
            a.seq_id    = (seq_s.empty() || seq_s == "?") ? -1 : std::stoi(seq_s);
            a.atom_name = row.str(7);                     // label_atom_id
            out.atoms.push_back(a);
        }

        // ---- BONDS 1: _struct_conn (authoritative cross-residue links) ----
        if (auto conn_tbl = block.find("_struct_conn.", {
                "ptnr1_label_atom_id","ptnr1_label_asym_id","ptnr1_label_seq_id",
                "ptnr2_label_atom_id","ptnr2_label_asym_id","ptnr2_label_seq_id"
            }); conn_tbl.ok()) {

            for (auto row : conn_tbl) {
                const std::string a1 = row.str(0), c1 = row.str(1), s1s = row.str(2);
                const std::string a2 = row.str(3), c2 = row.str(4), s2s = row.str(5);
                const int s1 = (s1s.empty() || s1s == "?") ? -1 : std::stoi(s1s);
                const int s2 = (s2s.empty() || s2s == "?") ? -1 : std::stoi(s2s);
                add_bond(findAtomIndex(c1, s1, a1), findAtomIndex(c2, s2, a2));
            }
        }

        // ---- BONDS 2: _chem_comp_bond (ALWAYS apply within residue) ----
        // Build list of (comp_id, atom_name_1, atom_name_2) templates.
        std::vector<std::tuple<std::string,std::string,std::string>> comp_pairs;

        if (auto comp_tbl = block.find("_chem_comp_bond.", {"comp_id","atom_id_1","atom_id_2"}); comp_tbl.ok()) {
            for (auto row : comp_tbl) comp_pairs.emplace_back(row.str(0), row.str(1), row.str(2));
        } else if (auto comp_tbl_min = block.find("_chem_comp_bond.", {"atom_id_1","atom_id_2"}); comp_tbl_min.ok()) {
            // no comp_id provided → wildcard (apply to any residue)
            for (auto row : comp_tbl_min) comp_pairs.emplace_back(std::string("*"), row.str(0), row.str(1));
        }

        if (!comp_pairs.empty()) {
            const int n = (int)out.atoms.size();
            for (int i = 0; i < n; ++i) {
                const auto& ai = out.atoms[i];
                for (const auto& tpl : comp_pairs) {
                    const std::string& comp = std::get<0>(tpl);
                    const std::string& n1   = std::get<1>(tpl);
                    const std::string& n2   = std::get<2>(tpl);
                    if (comp != "*" && comp != ai.residue) continue;

                    // connect within SAME residue instance (same chain + seq_id)
                    for (int j = i + 1; j < n; ++j) {
                        const auto& aj = out.atoms[j];
                        if (aj.chain != ai.chain || aj.seq_id != ai.seq_id) continue;
                        if ((ai.atom_name == n1 && aj.atom_name == n2) ||
                            (ai.atom_name == n2 && aj.atom_name == n1)) {
                            add_bond(i, j);
                        }
                    }
                }
            }
        }
    }
    catch (const std::exception& e) {
        std::cerr << "loadCifAtomsAndBonds threw: " << e.what() << "\n";
    }
    catch (...) {
        std::cerr << "loadCifAtomsAndBonds threw unknown exception\n";
    }

    return out;
}
}  // namespace io
}  // namespace TissueForge

