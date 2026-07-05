# Argus Neural Codec

The Argus Neural Codec contains the gateware configuration for neural coding and decoding with the Argus Cybernetics stack. Is safely provided to the rest of the ROS graph by the Argus Safety Controller. The long term plan is to:

- [ ] 1. Migrate the current neural decoding logic from the Argus Safety Controller to the gateware in this repo while providing safe access to the gateware for the rest of the Argus Cybernetics Stack's ROS graph. This will target the Arty Z7'sPL.

- [ ] 3. Modify the Argus Cybernetics Stack implementation to be a closed-loop interface(not sure what that's going to look like yet).