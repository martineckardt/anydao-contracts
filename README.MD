# AnyDAO Cross-chain Governance Protocol
anyDAO is a cross-chain governance protocol that makes cross-chain voting and governance possible.

## Problem
Multi-chain projects face many challenges in governance. If there is no cross-chain governance, the protocolls have to options: 
- They may either hold the governance on a single chain and require all the governance toke holders to move their tokens to the governance chain
- They have independet governance on each chain. This may result in communities deciding differently on proposals and have the protocolls on the chains drift apart.

## Solution
Enable cross-chain governance to make it possible to vote on the same proposals from different chains. Therefore, all governance token holders are included in the governance without requiring them to move their coins and pay gas fees for this.

## Contracts Overview
This project was created to illustrate that cross-chain governance is possible using LayerZero. For simplicity, we decided to go with a parent-child pattern, where the proposal happens in one chain but multiple chains can vote in it, this pattern can be upgraded in the future to a more well-connected one.

### How it works
The governance model was heavily inspired by Compound Finance GovernorAlpha codebase, working quite similarly to it. 

We added that when a proposal is created in the parent chain, it triggers the creation of polls in the child chains. When the `endBlock` for the proposal arrives, the proposal enters in the Aggregating state, permitting anyone to close the side polls, sending the vote results to the parent chain, where it will be counted to change the proposal status to either Succeeded or Defeated.

![Proposal Flow](proposal_flow.png)

# Dependencies
This project uses Brownie. All hail Brownie!
Installing it via `pipx`:
```
pipx install eth-brownie
```
or via `pip`:
```
pip install eth-brownie
```