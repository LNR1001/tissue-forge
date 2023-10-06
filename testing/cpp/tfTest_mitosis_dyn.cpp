/*******************************************************************************
 * This file is part of Tissue Forge.
 * Copyright (c) 2022, 2023 T.J. Sego
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

#include "tfTest.h"


using namespace TissueForge;


struct CellType : ParticleType {

    CellType() : ParticleType(true) {
        radius = 0.5;
        target_energy = 0;
        radius = 0.5;
        registerType();
    };

};


HRESULT fission(const event::ParticleTimeEvent &event) {
    event.targetParticle->fission();
    return S_OK;
};


int main(int argc, char const *argv[])
{
    Simulator::Config config;
    config.setWindowless(true);
    config.universeConfig.dim = {20, 20, 20};
    TF_TEST_CHECK(tfTest_init(config));

    FloatP_t pot_min = 0.1;
    FloatP_t pot_max = 1.0;
    Potential *pot = Potential::coulomb(10, &pot_min, &pot_max);

    CellType *Cell = new CellType();
    Cell = (CellType*)Cell->get();

    TF_TEST_CHECK(bind::types(pot, Cell, Cell));

    FVector3 pos(10.0);
    (*Cell)(&pos);

    event::onParticleTimeEvent(Cell, 1.0, new event::ParticleTimeEventMethod(&fission), NULL, 0, 0, -1, (unsigned int)event::TimeEventTimeSetterEnum::EXPONENTIAL);

    // run the simulator
    TF_TEST_CHECK(step(Universe::getDt() * 100));

    return S_OK;
}
