pragma solidity^0.4.16;

contract Verifyer {
    event EventVerificationSucceeded(bytes Signature, bytes32 Message, address Key);
    event EventVerificationFailed(bytes Signature, bytes32 Message, address Key);

    /*
    * This functionality verifies ECDSA signatures
    * @returns true if the _signature of _address over _message is correct
    */
    function verify(address _address, bytes32 _message, bytes _signature) public returns(bool) {
        if (_signature.length != 65)
            return false;

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := mload(add(_signature, 32))
            s := mload(add(_signature, 64))
            v := byte(0, mload(add(_signature, 96)))
        }

        if (v < 27)
            v += 27;

        if (v != 27 && v != 28)
            return false;

        address pk = ecrecover(_message, v, r, s);

        if (pk == _address) {
            EventVerificationSucceeded(_signature, _message, pk);
            return true;
        } else {
            EventVerificationFailed(_signature, _message, pk);
            return false;
        }
    }
}


contract MSContract is Verifyer {
    event EventInitializing(address addressAlice, address addressBob);
    event EventInitialized(uint cashAlice, uint cashBob);
    event EventRefunded();
    event EventStateRegistering();
    event EventStateRegistered(uint blockedAlice, uint blockedBob);
    event EventClosing();
    event EventClosed();
    event EventNotClosed();
    event Debug();

    modifier AliceOrBob { require(msg.sender == alice.id || msg.sender == bob.id); _;}

    //Data type for Internal Contract
    struct Party {
        address id;
        uint cash;
        bool waitForInput;
    }

    //Data type for Internal Contract
    struct InternalContract {
        bool active;
        VPC vpc;
        uint sid;
        uint blockedA;
        uint blockedB;
        uint version;
    }

    // State options
    enum ChannelStatus {Init, Open, InConflict, Settled, WaitingToClose, ReadyToClose}

    // MSContract variables
    Party public alice;
    Party public bob;
    uint public timeout;
    InternalContract public c;
    ChannelStatus public status;

    /*
    * Constructor for setting initial variables takes as input
    * addresses of the parties of the basic channel
    */
    function MSContract(address _addressAlice, address _addressBob) public {
        // set addresses
        alice.id = _addressAlice;
        bob.id = _addressBob;

        // set limit until which Alice and Bob need to respond
        timeout = now + 100 minutes;
        alice.waitForInput = true;
        bob.waitForInput = true;

        // set other initial values
        status = ChannelStatus.Init;
        c.active = false;
        EventInitializing(_addressAlice, _addressBob);
    }

    /*
    * This functionality is used to send funds to the contract during 100 minutes after channel creation
    */
    function confirm() public AliceOrBob payable {
        require(status == ChannelStatus.Init && now < timeout);

        // Response (in time) from Player A
        if (alice.waitForInput && msg.sender == alice.id) {
            alice.cash = msg.value;
            alice.waitForInput = false;
        }

        // Response (in time) from Player B
        if (bob.waitForInput && msg.sender == bob.id) {
            bob.cash = msg.value;
            bob.waitForInput = false;
        }

        // execute if both players responded
        if (!alice.waitForInput && !bob.waitForInput) {
            status = ChannelStatus.Open;
            timeout = 0;
            EventInitialized(alice.cash, bob.cash);
        }
    }

    /*
    * This function is used in case one of the players did not confirm the MSContract in time
    */
    function refund() public AliceOrBob {
        require(status == ChannelStatus.Init && now > timeout);

        // refund money
        if (alice.waitForInput && alice.cash > 0) {
            require(alice.id.send(alice.cash));
        }
        if (bob.waitForInput && bob.cash > 0) {
            require(bob.id.send(bob.cash));
        }
        EventRefunded();

        // terminate contract
        selfdestruct(alice.id);
    }

    /*
    * This functionality is called whenever the channel state needs to be established
    * it is called by both, alice and bob
    * Afterwards the parties have to interact directly with the VPC
    * and at the end they should call the execute function
    * @param     contract address: vpc, _sid,
                 blocked funds from A and B: blockedA and blockedB,
                 version parameter: version,
    *            signature parameter (from A and B): sigA, sigB
    */
    function stateRegister(address _vpc, 
                           uint _sid, 
                           uint _blockedA, 
                           uint _blockedB, 
                           uint _version, 
                           bytes sigA, 
                           bytes sigB) public AliceOrBob {
        // check if the parties have enough funds in the contract
        require((alice.cash > _blockedA || bob.cash > _blockedB));

        // verfify correctness of the signatures
        bytes32 msgHash = keccak256(_vpc, _sid, _blockedA, _blockedB, _version);
        require(verify(alice.id, msgHash, sigA)
               && verify(bob.id, msgHash, sigB));

        // execute on first call
        if (status == ChannelStatus.Open || status == ChannelStatus.WaitingToClose) {
            status = ChannelStatus.InConflict;
            alice.waitForInput = true;
            bob.waitForInput = true;
            timeout = now + 100 minutes;
            EventStateRegistering();
        }
        if (status != ChannelStatus.InConflict) return;

        // record if message is sent by alice and bob
        if (msg.sender == alice.id) alice.waitForInput = false;
        if (msg.sender == bob.id) bob.waitForInput = false;

        // set values of InternalContract
        if (_version > c.version) {
            c.active = true;
            c.vpc = VPC(_vpc);
            c.sid = _sid;
            c.blockedA = _blockedA;
            c.blockedB = _blockedB;
            c.version = _version;
        }

        // execute if both players responded
        if (!alice.waitForInput && !bob.waitForInput) {
            status = ChannelStatus.Settled;
            alice.waitForInput = false;
            bob.waitForInput = false;
            alice.cash -= c.blockedA;
            bob.cash -= c.blockedB;
            EventStateRegistered(c.blockedA, c.blockedB);
        }
    }

    /*
    * This function is used in case one of the players did not confirm the state
    */
    function finalizeRegister() public AliceOrBob {
        require(status == ChannelStatus.InConflict && now > timeout);

        status = ChannelStatus.Settled;
        alice.waitForInput = false;
        bob.waitForInput = false;
        alice.cash -= c.blockedA;
        bob.cash -= c.blockedB;
        EventStateRegistered(c.blockedA, c.blockedB);
    }

    /*
    * This functionality executes the internal VPC Machine when its state is settled
    * The function takes as input addresses of the parties of the virtual channel
    */
    function execute(address _alice, 
                     address _ingrid, 
                     address _bob) public AliceOrBob {
        require(status == ChannelStatus.Settled);

        // call virtual payment machine on the params
        var (s, a, b) = c.vpc.finalize(_alice, _ingrid, _bob, c.sid);

        // check if the result makes sense
        if (!s) return;

        // update balances only if they make sense
        if (a + b == c.blockedA + c.blockedB) {
            alice.cash += a;
            c.blockedA -= a;
            bob.cash += b;
            c.blockedB -= b;
        }

        // send funds to A and B
        if (alice.id.send(alice.cash)) alice.cash = 0;
        if (bob.id.send(bob.cash)) bob.cash = 0;

        // terminate channel
        if (alice.cash == 0 && bob.cash == 0) {
            EventClosed();
            selfdestruct(alice.id);
        }
    }

    /*
    * This functionality closes the channel when there is no internal machine
    */
    function close() public AliceOrBob {
        if (status == ChannelStatus.Open) {
            status = ChannelStatus.WaitingToClose;
            timeout = now + 300 minutes;
            alice.waitForInput = true;
            bob.waitForInput = true;
            EventClosing();
        }

        if (status != ChannelStatus.WaitingToClose) return;

        // Response (in time) from Player A
        if (alice.waitForInput && msg.sender == alice.id)
            alice.waitForInput = false;

        // Response (in time) from Player B
        if (bob.waitForInput && msg.sender == bob.id)
            bob.waitForInput = false;

        if (!alice.waitForInput && !bob.waitForInput) {
            // send funds to A and B
            if (alice.id.send(alice.cash)) alice.cash = 0;
            if (bob.id.send(bob.cash)) bob.cash = 0;

            // terminate channel
            if (alice.cash == 0 && bob.cash == 0) {
                selfdestruct(alice.id);
                EventClosed();
            }
        }
    }

    function finalizeClose() public AliceOrBob {
        if (status != ChannelStatus.WaitingToClose) {
            EventNotClosed();
            return;
        }

        // execute if timeout passed
        if (now > timeout) {
            // send funds to A and B
            if (alice.id.send(alice.cash)) alice.cash = 0;
            if (bob.id.send(bob.cash)) bob.cash = 0;

            // terminate channel
            if (alice.cash == 0 && bob.cash == 0) {
                selfdestruct(alice.id);
                EventClosed();
            }
        }
    }
}


contract VPC is Verifyer {
    event EventVpcClosing(bytes32 indexed _id);
    event EventVpcClosed(bytes32 indexed _id, uint cashAlice, uint cashBob);

    // datatype for virtual state
    struct VpcState {
        uint AliceCash;
        uint BobCash;
        uint seqNo;
        uint validity;
        uint extendedValidity;
        bool open;
        bool waitingForAlice;
        bool waitingForBob;
        bool init;
    }

    // datatype for virtual state
    mapping (bytes32 => VpcState) public states;
    VpcState public s;
    bytes32 public id;

    /*
    * This function is called by any participant of the virtual channel
    * It is used to establish a final distribution of funds in the virtual channel
    */
    function close(address alice, address ingrid, address bob, uint sid, uint version, uint aliceCash, uint bobCash,
            bytes signA, bytes signB) public {
        require(msg.sender == alice || msg.sender == ingrid || msg.sender == bob);

        id = keccak256(alice, ingrid, bob, sid);
        s = states[id];
        
        // verfiy signatures
        bytes32 msgHash = keccak256(id, version, aliceCash, bobCash);
        require(verify(alice, msgHash, signA) && verify(bob, msgHash, signB));

        // if such a virtual channel state does not exist yet, create one
        if (!s.init) {
            uint validity = now + 10 minutes;
            uint extendedValidity = validity + 10 minutes;
            s = VpcState(aliceCash, bobCash, version, validity, extendedValidity, true, true, true, true);
            EventVpcClosing(id);
        }

        // if channel is closed or timeouted do nothing
        if (!s.open || s.extendedValidity < now) return;
        if ((s.validity < now) && (msg.sender == alice || msg.sender == bob)) return;
 
        // check if the message is from alice or bob
        if (msg.sender == alice) s.waitingForAlice = false;
        if (msg.sender == bob) s.waitingForBob = false;

        // set values of Internal State
        if (version > s.seqNo) {
            s = VpcState(aliceCash, bobCash, version, s.validity, s.extendedValidity, true, s.waitingForAlice, s.waitingForBob, true);
        }

        // execute if both players responded
        if (!s.waitingForAlice && !s.waitingForBob) {
            s.open = false;
            EventVpcClosed(id, s.AliceCash, s.BobCash);
        }
        states[id] = s;
    }

    /*
    * For the virtual channel with id = (alice, ingrid, bob, sid) this function:
    *   returns (false, 0, 0) if such a channel does not exist or is neither closed nor timeouted, or
    *   return (true, a, b) otherwise, where (a, b) is a final distribution of funds in this channel
    */
    function finalize(address alice, address ingrid, address bob, uint sid) public returns (bool, uint, uint) {
        id = keccak256(alice, ingrid, bob, sid);
        if (states[id].init) {
            if (states[id].extendedValidity < now) {
                states[id].open = false;
                EventVpcClosed(id, states[id].AliceCash, states[id].BobCash);
            }
            if (states[id].open)
                return (false, 0, 0);
            else
                return (true, states[id].AliceCash, states[id].BobCash);
        }
        else
            return (false, 0, 0);
    }
}
