# ******************************************************************************
# This file is part of Tissue Forge.
# Copyright (c) 2022, 2023 T.J. Sego
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU Lesser General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
# 
# ******************************************************************************

import tissue_forge as tf

tf.init()


class AType(tf.ParticleTypeSpec):
    radius = 0.25
    species = ['S1', 'S2', 'S3']
    style = {"colormap": {"species": "S1",
                          "map": "rainbow",
                          "range": (0, 1)}}


A = AType.get()
tf.Fluxes.flux(A, A, "S1", 5)

a1 = A(tf.Universe.center)
a2 = A(tf.Universe.center + [0, 0.5, 0])

a1.species.S1 = 0
a2.species.S1 = 1

tf.run()
