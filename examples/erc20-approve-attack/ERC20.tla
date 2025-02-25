----------------------------- MODULE ERC20 ------------------------------------
(*
 * Modeling ERC20 tokens of Ethereum and the Approve-TransferFrom Attack:
 *
 * EIP-20: https://eips.ethereum.org/EIPS/eip-20
 *
 * Attack scenario:
 * https://docs.google.com/document/d/1YLPtQxZu1UAvO9cZ1O2RPXBbT0mooh4DYKjA_jp-RLM/edit#
 *
 * This TLA+ specification is designed for model checking with Apalache.
 * We do not model 256-bit integers here, as we are not interested in overflows.
 * 
 * Igor Konnov, Informal Systems, 2021-2022
 *)
EXTENDS Integers, ERC20_typedefs

CONSTANTS
    \* Set of all addresses.
    \* 
    \* @type: Set(ADDR);
    ADDR,
    \* Set of the amounts to use.
    \* 
    \* @type: Set(Int);
    AMOUNTS

VARIABLES
    \* Token balance for every account. This is exactly as `balanceOf` in ERC20.
    \*
    \* @type: ADDR -> Int;
    balanceOf,
    \* Allowance to transfer tokens
    \* from owner (1st element) by spender (2nd element).
    \* This is exactly as `allowance` of ERC20.
    \*
    \* @type: <<ADDR, ADDR>> -> Int;
    allowance

\* Variables that model Ethereum transactions, not the ERC20 state machine.
VARIABLES    
    \* Pending transactions to be executed against the contract.
    \* Note that we have a set of transactions instead of a sequence,
    \* as the order of transactions on Ethereum is not predefined.
    \* To make it possible to submit two 'equal' transactions,
    \* we introduce a unique transaction id.
    \*
    \* @type: Set(TX);
    pendingTransactions,
    \* The last executed transaction.
    \*
    \* @type: TX;
    lastTx,
    \* A serial number to assign unique ids to transactions
    \* @type: Int;
    nextTxId

vars ==
    <<balanceOf, allowance, pendingTransactions, lastTx, nextTxId>>

\* Initialize an ERC20 token.
Init ==
    \* every address has a non-negative number of tokens
    /\ balanceOf \in [ADDR -> AMOUNTS]
    /\ \A a \in ADDR: balanceOf[a] >= 0
    \* no account is allowed to withdraw from another account
    /\ allowance = [ pair \in ADDR \X ADDR |-> 0 ]
    \* no pending transactions
    /\ pendingTransactions = {}
    /\ nextTxId = 0
    /\ lastTx = [ id |-> 0, tag |-> "None", fail |-> FALSE ]

(* EIP-20:
The following action submits a transaction to the blockchain.

Transfers _value amount of tokens to address _toAddr, and MUST fire the Transfer
event. The function SHOULD throw if the message caller’s account balance does
not have enough tokens to spend.

Note Transfers of 0 values MUST be treated as normal transfers and fire the
Transfer event.
*)
SubmitTransfer(_sender, _toAddr, _value) == 
    LET newTx == [ id |-> nextTxId, tag |-> "transfer", fail |-> FALSE,
                   sender |-> _sender, toAddr |-> _toAddr, value |-> _value ]
    IN
    /\ pendingTransactions' = pendingTransactions \union { newTx }
    /\ lastTx' = [ id |-> 0, tag |-> "None", fail |-> FALSE ]
    /\ nextTxId' = nextTxId + 1
    /\ UNCHANGED <<balanceOf, allowance>>

(*
 Process a Transfer transaction that was submitted with SubmitTransfer.
 *)
CommitTransfer(_tx) == 
    /\ _tx.tag = "transfer"
    /\ pendingTransactions' = pendingTransactions \ { _tx }
    /\  LET fail ==
          \/ _tx.value < 0
          \/ _tx.value > balanceOf[_tx.sender]
          \/ _tx.sender = _tx.toAddr
        IN
        /\ lastTx' = [ _tx EXCEPT !.fail = fail ]
        /\ IF fail
          THEN UNCHANGED <<balanceOf, allowance, nextTxId>>
          ELSE \* transaction succeeds
               \* update the balances of the 'sender' and 'toAddr' addresses
            /\ balanceOf' = [
                 balanceOf EXCEPT ![_tx.sender] = @ - _tx.value,
                                  ![_tx.toAddr] = @ + _tx.value
               ]
            /\ UNCHANGED <<allowance, nextTxId>>

(* EIP-20:
Transfers _value amount of tokens from address _fromAddr to address _toAddr, and
MUST fire the Transfer event.

The transferFrom method is used for a withdraw workflow, allowing contracts to
transfer tokens on your behalf. This can be used for example to allow a
contract to transfer tokens on your behalf and/or to charge fees in
sub-currencies. The function SHOULD throw unless the _fromAddr account has
deliberately authorized the sender of the message via some mechanism.

Note Transfers of 0 values MUST be treated as normal transfers and fire the
Transfer event.
*)
SubmitTransferFrom(_sender, _fromAddr, _toAddr, _value) == 
    LET newTx == [
            id |-> nextTxId,
            tag |-> "transferFrom", fail |-> FALSE, sender |-> _sender,
            fromAddr |-> _fromAddr, toAddr |-> _toAddr, value |-> _value
        ]
    IN
    /\ pendingTransactions' = pendingTransactions \union { newTx }
    /\ lastTx' = [ id |-> 0, tag |-> "None", fail |-> FALSE ]
    /\ nextTxId' = nextTxId + 1
    /\ UNCHANGED <<balanceOf, allowance>>

(*
 Process a TranferFrom transaction that was submitted with SubmitTransferFrom.
 *)
CommitTransferFrom(_tx) == 
    /\ _tx.tag = "transferFrom"
    /\ pendingTransactions' = pendingTransactions \ { _tx }
    /\  LET fail ==
          \/ _tx.value < 0
          \/ _tx.value > balanceOf[_tx.fromAddr]
          \/ _tx.value > allowance[_tx.fromAddr, _tx.sender]
          \/ _tx.fromAddr = _tx.toAddr
        IN
        /\ lastTx' = [ _tx EXCEPT !.fail = fail ]
        /\  IF fail
            THEN UNCHANGED <<balanceOf, allowance, nextTxId>>
            ELSE \* transaction succeeds
            \* update the balances of the 'fromAddr' and 'toAddr' addresses
            /\ balanceOf' = [ balanceOf EXCEPT
                  ![_tx.fromAddr] = @ - _tx.value,
                  ![_tx.toAddr] = @ + _tx.value
               ]
            \* decrease the allowance for the sender
            /\ allowance' = [ allowance EXCEPT
                  ![_tx.fromAddr, _tx.sender] = @ - _tx.value
               ]
            /\ UNCHANGED nextTxId

(* EIP-20:
Allows _spender to withdraw from your account multiple times, up to the _value
amount. If this function is called again it overwrites the current allowance
with _value.
*)
SubmitApprove(_sender, _spender, _value) == 
    LET newTx == [
            id |-> nextTxId,
            tag |-> "approve", fail |-> FALSE,
            sender |-> _sender, spender |-> _spender, value |-> _value
        ]
    IN
    /\ pendingTransactions' = pendingTransactions \union { newTx }
    /\ lastTx' = [ id |-> 0, tag |-> "None", fail |-> FALSE ]
    /\ nextTxId' = nextTxId + 1
    /\ UNCHANGED <<balanceOf, allowance>>

\* Process an Approve transaction that was submitted with SubmitApprove.
CommitApprove(_tx) ==
    /\ _tx.tag = "approve"
    /\ pendingTransactions' = pendingTransactions \ { _tx }
    /\ UNCHANGED <<balanceOf, nextTxId>>
    /\  LET fail == _tx.value < 0 \/ _tx.sender = _tx.spender IN
        /\ lastTx' = [ _tx EXCEPT !.fail = fail ]
        /\  IF fail
            THEN \* transaction fails
              UNCHANGED allowance
            ELSE \* transaction succeeds
              \* set the allowance for the pair <<sender, spender>> to value
              allowance' =
                [ allowance EXCEPT ![_tx.sender, _tx.spender] = _tx.value ]
        
\* The transition relation, which chooses one of the actions
Next ==
    \/ \E sender, toAddr \in ADDR:
         \E value \in AMOUNTS:
           SubmitTransfer(sender, toAddr, value)
    \/ \E sender, fromAddr, toAddr \in ADDR:
         \E value \in AMOUNTS:
           SubmitTransferFrom(sender, fromAddr, toAddr, value)
    \/ \E sender, spender \in ADDR:
         \E value \in AMOUNTS:
           SubmitApprove(sender, spender, value)
    \/ \E tx \in pendingTransactions:
        CommitTransfer(tx)
    \/ \E tx \in pendingTransactions:
        CommitTransferFrom(tx)
    \/ \E tx \in pendingTransactions:
        CommitApprove(tx)

(* False invariants to debug the spec *)

\* Claim that no `TransferFrom` transaction is ever processed.
\* This is false. Use this false invariant to see an example of how
\* `TransferFrom` is processed.
NoTransferFrom ==
    LET Example ==
        /\ ~lastTx.fail
        /\ lastTx.tag = "transferFrom"
        /\ lastTx.value > 0
    IN
    ~Example

\* Claim that no `Approve` transaction is ever processed.
\* This is false. Use this false invariant to see an example of how
\* `Approve` is processed.
NoApprove ==
    LET Example ==
        /\ ~lastTx.fail
        /\ lastTx.tag = "approve"
        /\ lastTx.value > 0
    IN
    ~Example

\* EXPECTED PROPERTIES

\* No transferFrom should be possible, while there is a pending approval
\* for a smaller amount. This invariant is violated, as explained in:
\*
\* https://docs.google.com/document/d/1YLPtQxZu1UAvO9cZ1O2RPXBbT0mooh4DYKjA_jp-RLM/edit#
NoTransferFromWhileApproveInFlight ==
    LET BadExample ==
        /\ lastTx.tag = "transferFrom"
        /\ lastTx.value > 0
        /\ ~lastTx.fail
        /\ \E approval \in pendingTransactions:
            /\ approval.tag = "approve"
            /\ approval.sender = lastTx.fromAddr
            /\ approval.spender = lastTx.sender
            /\ lastTx.sender /= lastTx.toAddr
            /\ approval.value < lastTx.value
            /\ approval.value > 0
    IN
    ~BadExample \*\/ BadExample

\* Make sure that the account balances never go negative.
NoNegativeBalances ==
    \A a \in ADDR:
        balanceOf[a] >= 0
====
\* A trace invariant: For every pair <<spender, fromAddr>>, the sum of transfers
\* via TransferFrom is no greater than the maximum allowance.
\* It is quite hard to formulate this property, as there are scenarios,
\* where this behavior is actually expected.
\* In pure TLA+, we would have to write a temporal property.
\* In Apalache, we are just writing a trace invariant.
\* 
\* @type: Seq(STATE) => Bool;
NoTransferAboveApproved(trace) ==
    \A spender, fromAddr \in ADDR:
        LET TransferIndices == {
            i \in DOMAIN trace:
                LET tx == trace[i].lastTx IN
                /\ tx.tag = "transferFrom"
                /\ ~tx.fail
                /\ tx.fromAddr = fromAddr
                /\ tx.sender = spender
                /\ tx.value > 0
        }
        IN
        \* the sum of all transfers from 'fromAddr' to 'toAddr'
        LET sumTransfers ==
            LET Add(sum, i) == sum + trace[i].lastTx.value IN
            ApaFoldSet(Add, 0, TransferIndices)
        IN
        \* there exists an approval for the whole transfer sum
        LET existsApprovalForSumInPast ==
          \E i \in DOMAIN trace:
            LET tx_i == trace[i].lastTx IN
            \* all transfers are made after the approval
            /\ \A j \in TransferIndices: j > i
            /\ tx_i.tag = "approve"
            /\ ~tx_i.fail
            \* the sender of this transaction is allowing the spender
            \* to spend at most the sum of the made transfers.
            /\ tx_i.value >= sumTransfers
            /\ spender = tx_i.spender
            /\ fromAddr = tx_i.sender
        IN
        sumTransfers > 0 => existsApprovalForSumInPast

===============================================================================
