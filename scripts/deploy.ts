// This script can be used to deploy the "Storage" contract using ethers.js library.
// Please make sure to compile "./contracts/1_Storage.sol" file before running this script.
// And use Right click -> "Run" from context menu of the file to run the script. Shortcut: Ctrl+Shift+S

import { deploy } from "./ethers-lib";

(async () => {
  try {
    const result = await deploy("StWSX", [
      "0xB1cB92619902DA57b8f0f910AE553222DE9ACc56",
      "0x3e64F88C6C7a1310236B242180c0Ba1409d10F4d",
      "0x2D4e10Ee64CCF407C7F765B363348f7F62D2E06e",
      "0xAEb6Cf65c48064aF0FA8554199CB8eAd499D92A5",
      "0x0dD2c0b61C8a8FF8Fbf84a82a188B81247d5AdFe",
    ]);
    console.log(`address: ${result.address}`);
  } catch (e) {
    console.log(e.message);
  }
})();
