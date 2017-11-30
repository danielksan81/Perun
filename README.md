## Perun Implementation

In this Git you will find a proof of concept implementation of the Perun Channels. The goal of this project is to build a decentralized trustless state channel network, which runs offline, fast and cheap based on top of the Ethereum Blockchain.

We are currently working on release 0.2 but we do not recomend to use this software to send real Ether, since this is still ongoing development.

## Prerequisite

- Node.js
- npm
- a working geth/parity instance (testrpc will generate a wrong signature and will not work properly!)
	- thus its recommended to use the [parity dev chain](https://github.com/paritytech/parity/wiki/Private-development-chain) with the '--geth' flag for instant mining

## Run 

Just install the necessary packages and then run the simulation.
```
$ npm install
$ node complete_walkthrough.js
```


