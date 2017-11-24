// XXX: NOTE THIS USES THE OLD web3.js 0.18.0 version, not the 1.0 API
function getContract(contractName, libAddress) {
    if (typeof libAddress !== 'undefined') {
        exec('solc --bin --abi --optimize --overwrite -o build/ --libraries LibSignatures:'+libAddress+' contracts/'+contractName+'.sol');
    } else {
        exec('solc --bin --abi --optimize --overwrite -o build/ contracts/'+contractName+'.sol');
    }

    // compile library first 
    var code = "0x" + fs.readFileSync("build/" + contractName + ".bin");
    var abi = fs.readFileSync("build/" + contractName + ".abi");
    var contract = web3.eth.contract(JSON.parse(abi));

    return {
        contract: contract,
        code: code
    };
}

function deployVPC(libAddress) {
    var vpc = getContract("VPC", libAddress);

    vpc.contract.new(
       {
         from: aliceAddr, 
         data: vpc.code, 
         gas: '4700000'
       }, function (e, contract){
           if (typeof contract.address !== 'undefined') {
               console.log('Contract mined! address: ' + contract.address + ' transactionHash: ' + contract.transactionHash);
               vpc = contract;
               deployMSContract(libAddress, contract);
           }
     });
}

function deployMSContract(libAddress, vpc) {
    var msc = getContract("MSContract", libAddress);

    msc.contract.new(
        aliceAddr,
        bobAddr,
       {
         from: aliceAddr, 
         data: msc.code, 
         gas: '4700000'
       }, function (e, contract){
           if (typeof contract.address !== 'undefined') {
               console.log('Contract mined! address: ' + contract.address + ' transactionHash: ' + contract.transactionHash);

               runSimulation(contract, vpc);
           }
     });
}

function runSimulation(msc, vpc) {
    var events = msc.allEvents({fromBlock: 0, toBlock: 'latest'});

    var initialized = false;

    events.watch(function(error, event) {
        if (!error) {

            if(event.event == "EventInitializing") {
                if (!initialized) {
                    initialized = true;
                    console.log("Channel Initialized for alice: "+event.args.addressAlice+" bob: "+event.args.addressBob);

                    // confirm from both accounts, real world this would obviously seperated
                    msc.confirm.sendTransaction({
                        from: aliceAddr,
                        value: web3.toWei(10, "ether")
                    }, function(err, txHash) {
                        if(err) {
                            console.log(err);
                        } else {
                        }
                    });
                    msc.confirm.sendTransaction({
                        from: bobAddr,
                        value: web3.toWei(10, "ether")
                    }, function(err, txHash) {
                        if(err) {
                            console.log(err);
                        } else {
                        }
                    });
                }

            } else if (event.event == "EventInitialized") {
                console.log("Both Parties confirmed alice put in: "+web3.fromWei(event.args.cashAlice, "ether")+" bob: "+web3.fromWei(event.args.cashBob, "ether"));

                // we assume both parties have agreed on these parameters here
                var sid = 1;
                var blockedAlice = web3.toWei(5, "ether");
                var blockedBob = web3.toWei(5, "ether");
                var version = 1;

                var msgHash = web3.sha3(vpc.address, sid, blockedAlice, blockedBob, version);
                var msgHash2 = web3.sha3(vpc.address, web3.toBigNumber(sid), blockedAlice, blockedBob, version);
                var sigAlice = web3.eth.sign(aliceAddr, msgHash);
                var sigAlice2 = web3.eth.sign(aliceAddr, web3.toHex(msgHash));
                var sigBob = web3.eth.sign(bobAddr, msgHash);

                msc.stateRegister.sendTransaction(
                    vpc.address,
                    sid,
                    blockedAlice,
                    blockedBob,
                    version,
                    sigAlice,
                    sigBob,
                    {from: aliceAddr}
                );
                console.log("Lib verification output: "+lib.verify.call(aliceAddr, msgHash, sigAlice));
                console.log("Hash "+msgHash);
                console.log("Hash2 "+msgHash2);
                console.log("Sig Alice "+sigAlice);
                console.log("Sig Alice2 "+sigAlice2);
                console.log("Addr Alice "+aliceAddr);
                console.log("Sig Bob "+sigBob);
                
            } else if (event.event == "EventStateRegistering") {
                console.log("State registered from participant")

            } else if (event.event == "Debug") {
                console.log("Debug message: "+event.args.message);

            } else {
                console.log("Debug message: "+event.args.message);
                //console.log("Unknown event: "+event.event);
            }
        } else {
            console.log(error);
            process.exit();
        }
    });
}

function setUpLibWatcher(lib) {
    var events = lib.allEvents({fromBlock: 0, toBlock: 'latest'});


    events.watch(function(error, event) {
        if (!error) {
            if(event.event == "EventVerificationSucceeded") {
                console.log("Successfull verification");
            } else if (event.event == "EventVerificationFailed") {
                console.log("Failed verification");
            }
        } else {
            console.log(error);
            process.exit();
        }
    });
}

// load web3, this assumes a running geth/parity instance
const Web3 = require('web3');
var web3;

if (typeof web3 !== 'undefined') {
  web3 = new Web3(web3.currentProvider);
} else {
  // set the provider you want from Web3.providers
  web3 = new Web3(new Web3.providers.HttpProvider("http://localhost:8545"));
}


const fs = require('fs');
const exec = require('child_process').execSync;

var lib = getContract("LibSignatures");

var aliceAddr = web3.eth.accounts[0];
var bobAddr = web3.eth.accounts[1];

web3.personal.unlockAccount(aliceAddr, "");
web3.personal.unlockAccount(bobAddr, "");

// preload Bobs account
web3.eth.sendTransaction({
    from: aliceAddr, 
    to: bobAddr, 
    value: web3.toWei(10, "ether")
});

var lib;
lib.contract.new(
   {
     from: aliceAddr, 
     data: lib.code, 
     gas: '4700000'
   }, function (e, contract){
    if (typeof contract.address !== 'undefined') {
        console.log('Contract mined! address: ' + contract.address + ' transactionHash: ' + contract.transactionHash);
        setUpLibWatcher(contract);
        lib = contract;
        deployVPC(contract.address);
    }
 });

