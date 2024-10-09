# <h1 align="center"> ProviderSubscriber System  </h1>

**The contract you are working on is a Provider-Subscriber system. It models a
marketplace where entities, referred to as "Providers", can offer some services for a
monthly fee. These services are consumed by entities known as "Subscribers". The
Providers and Subscribers interact with each other using a specific ERC20 token as
the medium of payment. Both Providers and Subscribers have their balances
maintained within the contract.**


## Getting Started
NB: The instructions below assumes that the dev has set up foundry and forge on their local machine

- clone the repo
- cd into the project
- run the following commands
```sh
forge install
forge build
forge test
```

Considerations for improvement in the code
* Gad Optimizations
  - When checking if a subscriber is part of a provider's list, I could have used bitmasking to remove the need for
  iteration. This will provide cheap constant time checks for a subscriber in a list of subscribers. For example
  ```solidity
    function isSubscriberRegistered(uint256 subscriberId) internal view returns (bool) {
        uint256 bitmaskIndex = (subscriberId - 1) / 256;
        uint256 bitPosition = (subscriberId - 1) % 256;
        return (subscriberIdBitmasks[bitmaskIndex] & (1 << bitPosition)) != 0;
    }
   ```
  - I generally used default types like `uint256` where I could have used smaller types to save storage. In a production
  environment, this would be a high consideration. 
  - More fine-grained authorization roles could have been defined, although I didn't think the functionalities needed
  it. But in a large scale system, this would be a high consideration for me. 


Bonus Section Considerations 
* Balance Management:
  * In order to manage a more robust balance management for subscribers, I would combine a design that includes 
  an off-chain and on-chain components
  * For the on-chain components, I would allow providers have a range of billing cycles (HOURS, DAY, WEEKS, MONTH, YEAR).
  However, I would represent these cycles using block numbers. With cycles represented as block numbers, it is easier
  to precisely calculate the billing cycle of a subscriber because block numbers are more accurate to track than 
  timestamp. For example, the block time on the Ethereum blockchain is ~13seconds, we can estimate the number of blocks 
  per cycle as:
  ```text
	    DAY: 1 days / 13 seconds ≈ 6,600 blocks per day
	    MONTH: 30 days / 13 seconds ≈ 199,692 blocks per 30-day month
	    YEAR: 365 days / 13 seconds ≈ 2,419,200 blocks per year
  ```
  Going by the example above, a subscriber who opts for a 1-day subscription would be charged after every 6,600 blocks.
  This is far more accurate than relying on block timestamp which can be manipulated. However, the caveat to this 
  approach is that block time differ on different blockchains, therefore this needs to he handled properly across board
  * The off-chain components of the design would have event listeners who listen for a new block and triggers a call
  to the smart contract to calculate and deduct payment for a new billing cycle after every block, resulting in a very
  accurate billing system.
* System Scalability:
  * Although the design in my solution uses a map to store providers, while still respecting the 200 providers 
  limitation. Theoretically using a map allows the contract to register an unlimited number of providers, I think the
  contract would be too cumbersome, and complicated to properly handle unlimited providers at scale.
  * My idea for how to scale this end-to-end would be to deploy a separate proxy contract for each provider through a 
  factory contract, and then allow each provider delegate calls to an implementation contract. There are multiple 
  benefits to this approach and they include:
    * The proxy contract would be highly configurable for the providers. Therefore, providers can explore various 
    combinations of billing cycles, payment tokens, discounts, possibly even gas-less transactions.
    * The providers can choose to deploy their proxy contract across any chain, instead of being limited to the chain
    our contract is deployed on
    * The providers can setup their own monitoring and automation infrastructure on their backend and frontend to 
    monitor the activities on their proxy contract, taking the load of managing infra for all providers off of us.
    
  This design has its drawbacks in terms of oversight on the provider's proxy contracts, and requiring providers to 
  have their own infrastructure, but these are just tradeoffs for scalability.
* Changing Provider Fees:
  * To design a fair fee management system for both providers and subscribers, I propose a transparent opt-in/opt-out
  system. In a transparent opt-in/opt-out system, the provider proposes a fee change and broadcasts the change to all 
  its current subscribers. This new fee change proposal does not go into effect until the next billing cycle, to 
  maintain fairness with the subscribers. And the fee change will be applied to a subscriber at the beginning the 
  next billing cycle if and only if they accept/opt-in the fee change proposal. If a subscriber does not accept the 
  fee change proposal, their subscription is paused. 
  * Designing this system would require end-to-end infrastructure. On the contract, we can track fee changes using an 
  Id. Whenever a new fee change is proposed, an event is emitted in the contract with the Id and other necessary data.
  This event is used to automate notifications on the frontend and backend. Before a new billing cycle is charged to a
  subscriber, the contract checks if the `lastProposalId` on the subscriber struct is the same as the `latestProposalId`
  in the provider contract or struct (as the case may be). The Ids are not the same, the contract will pause the 
  subscription until a time when the subscriber is ready to accept the new proposal. This ensurs that a subscriber is 
  not charged an amount they have not agreed to. 
  
