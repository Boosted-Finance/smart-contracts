require('@nomiclabs/hardhat-ethers');
const inquirer = require('inquirer');

let gasPrice;
async function fetchNextGasPrice(BN, message) {
  let question = [
    {
      type: 'input',
      name: 'gas',
      message: `Next gas price to use (in gwei) for ${message}`,
    },
  ];

  gasPrice = (await inquirer.prompt(question)).gas;
  gasPrice = new BN.from(gasPrice).mul(new BN.from(10).pow(new BN.from(9)));
}

let bVault;
let bVaultRewards;
let ethUsdcStrat;

task('orbVaults', 'deploy stuff for orbVaults').setAction(async (taskArgs,hre) => {
  const BN = ethers.BigNumber;
  // await hre.network.provider.request({
  //   method: "hardhat_impersonateAccount",
  //   params: ["0xd87e80bCd2527508b617dc33F4b73Dc5DdA200a2"]}
  // )
  // const deployer = await ethers.provider.getSigner("0xd87e80bCd2527508b617dc33F4b73Dc5DdA200a2");
  const [deployer] = await ethers.getSigners();
  let deployerAddress = await deployer.getAddress();
  console.log(`Deploying from ${deployerAddress}`);

  let stakeTokenAddress = "0x397FF1542f962076d0BFE58eA045FfA2d347ACa0"; // sushi ETH-USDC
  let BVault = await ethers.getContractFactory('BoostVault');
  let BVaultRewards = await ethers.getContractFactory('BoostVaultRewards');
  let Strat = await ethers.getContractFactory('SushiV2ETHUSDCStrategy');

  // deploy boost vault rewards
  await fetchNextGasPrice(BN, 'boost vault rewards deployment');
  bVaultRewards = await BVaultRewards.deploy(
    "0x3e780920601d61cedb860fe9c4a90c9ea6a35e78", // boost token
    deployerAddress // treasury
  );
  await bVaultRewards.deployed();
  console.log(`bVaultRewards: ${bVaultRewards.address}`);

  await fetchNextGasPrice(BN, 'boost vault deployment');
  bVault = await BVault.deploy(
    stakeTokenAddress,
    bVaultRewards.address
  );
  await bVault.deployed();
  console.log(`bVault: ${bVault.address}`);

  await fetchNextGasPrice(BN, 'boost strategy deployment');
  ethUsdcStrat = await Strat.deploy(
      bVault.address,
      bVaultRewards.address
  );
  await ethUsdcStrat.deployed();
  console.log(`strat: ${ethUsdcStrat.address}`);

  // set vault strat in bVault
  await fetchNextGasPrice(BN, 'set vault strat in bVault');
  await bVault.setVaultStrategy(ethUsdcStrat.address);

  // set vault token in bVaultRewards
  await fetchNextGasPrice(BN, 'set vault token in bVaultRewards');
  await bVaultRewards.setVaultToken(bVault.address);

  // add reward config, duration and distributor
  await fetchNextGasPrice(BN, 'setup reward config');
  await bVaultRewards.addRewardConfig(stakeTokenAddress, 1);
  await bVaultRewards.setRewardDistributor(stakeTokenAddress, [ethUsdcStrat.address], [true]);

  process.exit(0);
});
