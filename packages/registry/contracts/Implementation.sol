// SPDX-License-Identifier: GPL-3.0-or-later
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity ^0.8.0;

import '@openzeppelin/contracts/proxy/utils/Initializable.sol';

import '@mimic-fi/v2-helpers/contracts/auth/Authorizer.sol';

import './IRegistry.sol';

contract Implementation is Authorizer, Initializable {
    IRegistry public immutable registry;

    constructor(IRegistry _registry) {
        registry = _registry;
    }

    function namespace() external view returns (bytes32) {
        return registry.getNamespace(address(this));
    }

    function _initialize(address admin) internal onlyInitializing {
        _authorize(admin, Authorizer.authorize.selector);
        _authorize(admin, Authorizer.unauthorize.selector);
    }
}
