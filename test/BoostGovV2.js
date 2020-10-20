const {expectRevert, time} = require('@openzeppelin/test-helpers');
const {BN} = require('@openzeppelin/test-helpers/src/setup');
const {expect, assert} = require('chai');
const UniswapV2FactoryBytecode = require('@uniswap/v2-core/build/UniswapV2Factory.json');
const UniswapV2Router02Bytecode = require('@uniswap/v2-periphery/build/UniswapV2Router02.json');
const TruffleContract = require('@truffle/contract');
const BoostGov = artifacts.require('BoostGovV2');
const Treasury = artifacts.require('TreasuryV2')
const BoostToken = artifacts.require('BoostToken');
const TestToken = artifacts.require('Token');
const WETH = artifacts.require('WETH9');
require('chai').use(require('chai-as-promised')).use(require('chai-bn')(BN)).should();

function getCurrentBlockTime() {
  return new Promise(function (fulfill, reject) {
    web3.eth.getBlock('latest', false, function (err, result) {
      if (err) reject(err);
      else fulfill(result.timestamp);
    });
  });
}

function mineBlockAtTime(timestamp) {
  return new Promise((resolve, reject) => {
    web3.currentProvider.send.bind(web3.currentProvider)(
      {
        jsonrpc: '2.0',
        method: 'evm_mine',
        params: [timestamp],
        id: new Date().getTime(),
      },
      (err, res) => {
        if (err) {
          return reject(err);
        }
        resolve(res);
      }
    );
  });
}

const MAX_UINT256 = new BN(2).pow(new BN(256)).sub(new BN(1));

contract('BoostGovV2', ([governance, alice, bob, carol]) => {
  before('init uniswap, tokens, and governance', async () => {
    this.boost = await BoostToken.new({from: governance});
    this.weth = await WETH.new({from: governance});
    this.ycrv = await TestToken.new('Curve.fi yDAI/yUSDC/yUSDT/yTUSD', 'yDAI+yUSDC+yUSDT+yTUSD', '18', {
      from: governance,
    });

    // Setup Uniswap
    const UniswapV2Factory = TruffleContract(UniswapV2FactoryBytecode);
    const UniswapV2Router02 = TruffleContract(UniswapV2Router02Bytecode);
    UniswapV2Factory.setProvider(web3.currentProvider);
    UniswapV2Router02.setProvider(web3.currentProvider);
    this.uniswapV2Factory = await UniswapV2Factory.new(governance, {from: governance});
    this.uniswapV2Router = await UniswapV2Router02.new(this.uniswapV2Factory.address, this.weth.address, {
      from: governance,
    });

    // Create Uniswap pair
    await this.boost.approve(this.uniswapV2Router.address, MAX_UINT256, {from: governance});
    await this.ycrv.approve(this.uniswapV2Router.address, MAX_UINT256, {from: governance});
    await this.uniswapV2Factory.createPair(this.boost.address, this.weth.address, {from: governance});
    await this.uniswapV2Factory.createPair(this.ycrv.address, this.weth.address, {from: governance});
    await this.uniswapV2Router.addLiquidityETH(
      this.boost.address,
      web3.utils.toWei('10000'),
      '0',
      '0',
      governance,
      MAX_UINT256,
      {value: web3.utils.toWei('100'), from: governance}
    );
    await this.uniswapV2Router.addLiquidityETH(
      this.ycrv.address,
      web3.utils.toWei('10000'),
      '0',
      '0',
      governance,
      MAX_UINT256,
      {value: web3.utils.toWei('100'), from: governance}
    );

    // Deploy treasury
    this.treasury = await Treasury.new(
      this.uniswapV2Router.address,
      this.ycrv.address,
      this.boost.address,
      governance,
      {from: governance}
    );
    
    // Deploy governance
    this.gov = await BoostGov.new(this.boost.address, this.treasury.address, this.uniswapV2Router.address, {
      from: governance,
    });
    await this.treasury.setGov(this.gov.address, {from: governance});

    // Bootstrap BOOST treasury and user balances
    await this.ycrv.transfer(this.treasury.address, web3.utils.toWei('10000'), {from: governance});
    await this.boost.transfer(alice, web3.utils.toWei('1000'), {from: governance});
    await this.boost.transfer(bob, web3.utils.toWei('1000'), {from: governance});
    await this.boost.transfer(carol, web3.utils.toWei('50000'), {from: governance});

    // Set balances and approvals
    await this.weth.deposit({value: web3.utils.toWei('300'), from: governance});
    await this.weth.transfer(alice, web3.utils.toWei('100'), {from: governance});
    await this.weth.transfer(bob, web3.utils.toWei('100'), {from: governance});
    await this.weth.transfer(carol, web3.utils.toWei('100'), {from: governance});
    await this.boost.approve(this.gov.address, MAX_UINT256, {from: alice});
    await this.boost.approve(this.gov.address, MAX_UINT256, {from: bob});
    await this.boost.approve(this.gov.address, MAX_UINT256, {from: carol});
  });

  it('should have correct constants', async () => {
    assert.equal((await this.gov.PROPOSAL_PERIOD()).toString(), 2 * 24 * 60 * 60);
    assert.equal((await this.gov.LOCK_PERIOD()).toString(), 3 * 24 * 60 * 60);
    assert.equal(await this.gov.minimum(), web3.utils.toWei('13.37'));
    assert.equal(await this.gov.stablecoin(), this.ycrv.address);
  });

  it('should revert when proposing due to not staking BOOST', async () => {
    await expectRevert(
      this.gov.propose('https://gov.boosted.finance/', "Proposal 1", web3.utils.toWei('1'), alice, {from: alice}),
      'stake more boost'
    );
  });

  it('should successfully submit a proposal', async () => {
    const url = 'https://gov.boosted.finance/';
    const title = 'Proposal';
    const withdrawAmount = web3.utils.toWei('10');
    const withdrawAddress = alice;

    await this.gov.stake(web3.utils.toWei('100'), {from: alice});
    await this.gov.propose(url, title, withdrawAmount, withdrawAddress, {from: alice})

    const proposal = await this.gov.proposals(0);
    assert.equal((await this.gov.totalSupply()).toString(), web3.utils.toWei('100'));
    assert.equal(await this.gov.proposalCount(), 1);
    assert.equal(proposal['proposer'], alice);
    assert.equal(proposal['url'], url);
    assert.equal(proposal['withdrawAmount'], withdrawAmount);
    assert.equal(proposal['withdrawAddress'], alice);
  });

  it('should successfully vote for proposal', async () => {
    await this.gov.voteFor(0, {from: alice});

    const proposal = await this.gov.proposals(0);
    assert.equal(proposal['totalForVotes'].toNumber(), Math.sqrt(web3.utils.toWei('100')));
  });

  it('should successfully vote against proposal', async () => {
    await this.gov.stake(web3.utils.toWei('9'), {from: bob});
    await this.gov.voteAgainst(0, {from: bob});

    const proposal = await this.gov.proposals(0);
    assert.equal(proposal['totalAgainstVotes'].toNumber(), Math.sqrt(web3.utils.toWei('9')));
  });

  it('should allow to stake and vote more on earlier chosen side', async () => {
    await this.gov.stake(web3.utils.toWei('800'), {from: alice});
    await this.gov.voteFor(0, {from: alice});
    await this.gov.stake(web3.utils.toWei('16'), {from: bob});
    await this.gov.voteAgainst(0, {from: bob});

    const proposal = await this.gov.proposals(0);
    assert.equal(proposal['totalForVotes'].toNumber(), Math.sqrt(web3.utils.toWei('900')));
    assert.equal(proposal['totalAgainstVotes'].toNumber(), Math.sqrt(web3.utils.toWei('25')));
  });

  it('should revert when trying to switch votes', async () => {
    await expectRevert(this.gov.voteAgainst(0, {from: alice}), 'cannot switch votes');
    await expectRevert(this.gov.voteFor(0, {from: bob}), 'cannot switch votes');
  });

  it('should revert voting for non-existing proposal', async () => {
    await expectRevert(this.gov.voteFor('999', {from: alice}), '>end');
    await expectRevert(this.gov.voteAgainst('999', {from: alice}), '>end');
  });  

  it('should revert when trying to withdraw when vote locked', async () => {
    await expectRevert(this.gov.withdraw(web3.utils.toWei('10'), {from: alice}), 'tokens locked');
    await expectRevert(this.gov.withdraw(web3.utils.toWei('10'), {from: bob}), 'tokens locked');
  });

  it('should revert when trying to resolve ongoing proposal', async () => {
    await expectRevert(this.gov.resolveProposal(0, {from: alice}), 'ongoing proposal');
  });

  it('should revert when trying to resolve non-existing proposal', async () => {
    await expectRevert(this.gov.resolveProposal(999, {from: alice}), 'non-existent proposal');
  });

  it('should resolve proposal', async () => {
    const proposal = await this.gov.proposals(0);
    
    // Mine block and move timestamp to beyond proposal period
    await mineBlockAtTime(parseInt(proposal['start']) + (2 * 24 * 60 * 60));

    await this.gov.resolveProposal(0, {from: alice});
    assert.equal(await this.ycrv.balanceOf(alice), web3.utils.toWei('10'));
  });

  it('should fail to resolve proposal again', async () => {
    await expectRevert(
      this.gov.resolveProposal(0, {from: alice}),
      "already resolved"
    );
  });

  it('should resolve proposal but not receive funds due to quorum not being met', async () => {
    const url = 'https://gov.boosted.finance/';
    const title = 'Proposal';
    const withdrawAmount = web3.utils.toWei('10');
    const withdrawAddress = alice;

    const beforeBal = await this.ycrv.balanceOf(alice);
    await this.gov.stake(web3.utils.toWei('15000'), {from: carol});
    await this.gov.propose(url, title, withdrawAmount, withdrawAddress, {from: alice})
    await this.gov.voteFor(1, {from: alice});
    await this.gov.voteAgainst(1, {from: bob});

    const proposal = await this.gov.proposals(1);
    
    // Mine block and move timestamp to beyond proposal period
    await mineBlockAtTime(parseInt(proposal['start']) + (2 * 24 * 60 * 60));

    await this.gov.resolveProposal(1, {from: alice});
    assert.isTrue((await this.ycrv.balanceOf(alice)).eq(beforeBal)); // No change in yCRV balance
  });

  it('should resolve proposal but not receive funds due to against votes > for votes', async () => {
    const url = 'https://gov.boosted.finance/';
    const title = 'Proposal';
    const withdrawAmount = web3.utils.toWei('10');
    const withdrawAddress = alice;
    const beforeBal = await this.ycrv.balanceOf(alice);

    await this.gov.propose(url, title, withdrawAmount, withdrawAddress, {from: alice});
    await this.gov.voteFor(2, {from: alice});
    await this.gov.voteFor(2, {from: bob});
    await this.gov.voteAgainst(2, {from: carol});

    const proposal = await this.gov.proposals(2);
    
    // Mine block and move timestamp to beyond proposal period
    await mineBlockAtTime(parseInt(proposal['start']) + (2 * 24 * 60 * 60));

    await this.gov.resolveProposal(2, {from: alice});
    assert.isTrue((await this.ycrv.balanceOf(alice)).eq(beforeBal)); // No change in yCRV balance
  });

  it('should resolve proposal but proposer gets slashed due to MIN_QUORUM_PUNISHMENT and WITHDRAW_THRESHOLD', async () => {
    const url = 'https://gov.boosted.finance/';
    const title = 'Proposal';
    const withdrawAmount = web3.utils.toWei('1001');
    const withdrawAddress = alice;
    // Mine block and move timestamp to beyond proposal period
    await mineBlockAtTime(await getCurrentBlockTime() + (3 * 24 * 60 * 60));
    await this.gov.withdraw(web3.utils.toWei('800'), {from: alice});
    assert.isTrue((await this.gov.balanceOf(alice)).gt(new BN(0)));

    await this.gov.stake(web3.utils.toWei('35000'), {from: carol});
    await this.gov.propose(url, title, withdrawAmount, withdrawAddress, {from: alice})
    await this.gov.voteFor(3, {from: alice});

    const proposal = await this.gov.proposals(3);
    
    // Mine block and move timestamp to beyond proposal period
    await mineBlockAtTime(parseInt(proposal['start']) + (2 * 24 * 60 * 60));

    await this.gov.resolveProposal(3, {from: alice});
    assert.equal(await this.gov.balanceOf(alice), 0); // All BOOST balances is slashed
  });

  it('should be able to reward voters when treasury.rewardVoters() is called', async() => {
    await this.boost.transfer(this.treasury.address, web3.utils.toWei('5000'), {from: governance});
    await this.treasury.rewardVoters();
    // Mine block and move timestamp to beyond distribution period
    await mineBlockAtTime(await getCurrentBlockTime() + (3 * 24 * 60 * 60));
    assert.isTrue((await this.gov.rewardRate()).gt(new BN(0)));
    assert.isTrue((await this.gov.earned(bob)).gt(new BN(0)));
    assert.isTrue((await this.gov.earned(carol)).gt(new BN(0)));
  });

  it('should be able to claim reward when performing an action (Eg. stake)', async() => {
    let bobBal = await this.boost.balanceOf(bob);
    await this.gov.stake(1, {from: bob});
    assert.isTrue((await this.boost.balanceOf(bob)).gt(bobBal));
  });

  it('should successfully withdraw stake from governance', async () => {
    // Mine block and move timestamp to beyond proposal period
    await this.gov.withdraw(await this.gov.balanceOf(bob), {from: bob});
    await this.gov.withdraw(await this.gov.balanceOf(carol), {from: carol});
    assert.equal(await this.gov.balanceOf(bob), 0);
    assert.equal(await this.gov.balanceOf(carol), 0);
  });
});
