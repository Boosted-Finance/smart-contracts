usePlugin('@nomiclabs/buidler-ethers');
const fs = require('fs');
const path = require('path');
const BN = require('ethers').BigNumber;

const keypress = async () => {
  process.stdin.setRawMode(true)
  return new Promise(resolve => process.stdin.once('data', data => {
    const byteArray = [...data]
    if (byteArray.length > 0 && byteArray[0] === 3) {
      console.log('^C')
      process.exit(1)
    }
      process.stdin.setRawMode(false)
      resolve()
  }))
}

async function waitContinue() {
  console.log("Done! Press to proceed...");
  await keypress();
}

let configPath;

let gasPrice = new BN.from(32).mul(new BN.from(10).pow(new BN.from(9)));

let swapRouter;
let ycrv;
let boost;
let multisig;
let usdc;
let epochStart;
let cap;

let treasury;
let gov;
let bvault;
let controller;
let bvaultReward;
let strat;

task('bVaults', 'deploy stuff for bVaults').setAction(async () => {
  network = await ethers.provider.getNetwork();
  const [deployer] = await ethers.getSigners();
  let deployerAddress = await deployer.getAddress();

  let Treasury = await ethers.getContractFactory('TreasuryV2');
  let Gov = await ethers.getContractFactory('BoostGovV2');
  let BVault = await ethers.getContractFactory('BoostVault');
  let Controller = await ethers.getContractFactory('BoostController');
  let BVaultReward = await ethers.getContractFactory('BoostVaultRewards');
  let Strat = await ethers.getContractFactory('MStableStrat');

  configPath = path.join(__dirname, './bVaults.json');
  readParams(JSON.parse(fs.readFileSync(configPath, 'utf8')));

  // deploy treasury
  console.log("deploying treasury...");
  treasury = await Treasury.deploy(
    swapRouter,
    ycrv,
    boost,
    multisig,
    {gasPrice: gasPrice}
  );
  await treasury.deployed();
  console.log(`treasury address: ${treasury.address}`);
  await waitContinue();

  console.log(`trf treasury ownership to multisig...`);
  await treasury.transferOwnership(multisig, {gasPrice: gasPrice});
  await waitContinue();

  // deploy gov
  console.log("deploying gov...");
  gov = await Gov.deploy(
    boost,
    treasury.address,
    swapRouter,
    {gasPrice: gasPrice}
  );
  await gov.deployed();
  console.log(`gov address: ${gov.address}`);
  await waitContinue();

  console.log(`set gov in treasury...`);
  await treasury.setGov(gov.address, {gasPrice: gasPrice});
  await waitContinue();

  // deploy controller
  console.log("deploying controller...");
  controller = await Controller.deploy(
    deployerAddress,
    deployerAddress,
    treasury.address,
    boost,
    epochStart,
    {gasPrice: gasPrice}
  );
  await controller.deployed();
  console.log(`controller address: ${controller.address}`);
  await waitContinue();

  // deploy vault
  console.log("deploying vault...");
  bvault = await BVault.deploy(
    usdc,
    gov.address,
    controller.address,
    cap,
    {gasPrice: gasPrice}
  );
  await bvault.deployed();
  console.log(`usdc bvault address: ${bvault.address}`);
  await waitContinue();

  // deploy reward
  console.log("deploying reward...");
  bvaultReward = await BVaultReward.deploy(
      bvault.address,
      boost,
      controller.address,
      {gasPrice: gasPrice}
  );
  await bvaultReward.deployed();
  console.log(`usdc bvaultReward address: ${bvaultReward.address}`);
  await waitContinue();

  // deploy strat
  console.log("deploying strat...");
  strat = await Strat.deploy(
    controller.address,
    {gasPrice: gasPrice}
  );
  await strat.deployed();
  console.log(`strat address: ${strat.address}`);
  await waitContinue();
 
  console.log(`set rewards in controller...`);
  await controller.setRewards(bvaultReward.address, {gasPrice: gasPrice});
  await waitContinue();

  console.log(`set vault in controller...`);
  await controller.setVaultAndInitHarvestInfo(bvault.address, {gasPrice: gasPrice});
  await waitContinue();

  console.log(`approve strat...`);
  await controller.approveStrategy(strat.address, cap, {gasPrice: gasPrice});
  await waitContinue();

  // USDC -> approve musdcBpt
  console.log(`Giving USDC allowance in strat...`);
  await strat.setAllowances(usdc, ["0x72Cd8f4504941Bf8c5a21d1Fd83A96499FD71d2C"], true, {gasPrice: gasPrice});
  await waitContinue();

  // musdcBpt -> approve mPool
  console.log(`Giving BPT allowance in strat...`);
  await strat.setAllowances("0x72Cd8f4504941Bf8c5a21d1Fd83A96499FD71d2C", ["0x881c72D1e6317f10a1cDCBe05040E7564E790C80"], true, {gasPrice: gasPrice});
  await waitContinue();

  // MTA -> approve mtaGov and balProxy
  console.log(`Giving MTA allowance in strat...`);
  await strat.setAllowances(
    "0xa3BeD4E1c75D00fa6f4E5E6922DB7261B5E9AcD2",
    ["0xaE8bC96DA4F9A9613c323478BE181FDb2Aa0E1BF", "0x3E66B66Fd1d0b02fDa6C811Da9E0547970DB2f21"],
    true,
    {gasPrice: gasPrice}
  );
  await waitContinue();

  process.exit(0);
});

function readParams(jsonInput) {
  swapRouter = jsonInput.swapRouter;
  usdc = jsonInput.usdc;
  ycrv = jsonInput.ycrv;
  boost = jsonInput.boost;
  multisig = jsonInput.multisig;
  epochStart = jsonInput.epochStart;
  cap = jsonInput.cap;
}
