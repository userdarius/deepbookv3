// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::margin_account {

    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::object::{Self, ID, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::bag::{Self, Bag};
    use sui::clock::{Self, Clock};
    use sui::event;

    use deepbook::position::{Self, Position, SignedU128};

    // === Errors ===
    const ENotEnoughCollateral: u64 = 1;
    const EPositionNotFound: u64 = 2;
    const EInvalidAmount: u64 = 3;
    const EBalanceTooLowToPayFunding: u64 = 4; // Specific error for funding payment failure

    /// Represents a user's margin account for trading perpetuals.
    /// Generic over the type of collateral asset used.
    public struct MarginAccount<phantom CollateralAsset> has key, store {
        id: UID,
        owner: address, // Owner of the margin account
        collateral: Balance<CollateralAsset>,
        positions: Bag, // Stores Position objects, keyed by position ID
    }

    // --- Events ---
    public struct CollateralDeposited<phantom CollateralAsset> has copy, drop, store {
        margin_account_id: ID,
        amount: u64,
    }

    public struct CollateralWithdrawn<phantom CollateralAsset> has copy, drop, store {
        margin_account_id: ID,
        amount: u64,
    }

    public struct PositionOpened has copy, drop, store {
        margin_account_id: ID,
        position_id: ID,
    }

    public struct PositionClosed has copy, drop, store {
        margin_account_id: ID,
        position_id: ID,
        realized_pnl: SignedU128, // Profit or loss
    }

    public struct FundingPaymentProcessed<phantom CollateralAsset> has copy, drop, store {
        margin_account_id: ID,
        position_id: ID,
        payment_amount: SignedU128, // Positive if user received, negative if user paid
    }

    // --- Public-Mutative Functions ---

    public fun new<CollateralAsset>(ctx: &mut TxContext): MarginAccount<CollateralAsset> {
        MarginAccount {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            collateral: balance::zero<CollateralAsset>(),
            positions: bag::new(ctx),
        }
    }

    public fun deposit_collateral<CollateralAsset>(
        account: &mut MarginAccount<CollateralAsset>,
        collateral_coin: Coin<CollateralAsset>,
    ) {
        let amount = coin::value(&collateral_coin);
        assert!(amount > 0, EInvalidAmount);
        balance::join(&mut account.collateral, coin::into_balance(collateral_coin));
        event::emit(CollateralDeposited<CollateralAsset> {
            margin_account_id: object::id(account),
            amount,
        });
    }

    public fun withdraw_collateral<CollateralAsset>(
        account: &mut MarginAccount<CollateralAsset>,
        amount: u64,
        ctx: &mut TxContext // Needed for creating Coin
    ): Coin<CollateralAsset> {
        assert!(amount > 0, EInvalidAmount);
        assert!(balance::value(&account.collateral) >= amount, ENotEnoughCollateral);
        
        let withdrawn_balance = balance::split(&mut account.collateral, amount);
        let withdrawn_coin = coin::from_balance(withdrawn_balance, ctx);
        
        event::emit(CollateralWithdrawn<CollateralAsset> {
            margin_account_id: object::id(account),
            amount,
        });
        withdrawn_coin
    }

    public fun add_new_position<CollateralAsset>(
        account: &mut MarginAccount<CollateralAsset>,
        is_long: bool,
        quantity: u64,
        entry_price: u64,
        collateral_for_position: u64, 
        leverage: u64,
        current_cumulative_funding_per_unit: SignedU128,
        clock: &Clock,
        ctx: &mut TxContext
    ): ID { 
        let new_pos = position::new_position(
            object::id(account), 
            is_long,
            quantity,
            entry_price,
            collateral_for_position, 
            leverage,
            current_cumulative_funding_per_unit,
            clock::timestamp_ms(clock),
            ctx
        );
        
        // Get the ID of the newly created Position object to use as a key in the bag.
        // Position struct has `id: UID`. We need an accessor in `position.move` like `get_uid(&Position): &UID`.
        // Then its ID can be `object::uid_to_inner(position::get_uid(&new_pos))`
        let new_pos_key = object::uid_to_inner(position::get_uid(&new_pos)); // Assumes position::get_uid() exists
        bag::add(&mut account.positions, new_pos_key, new_pos);

        event::emit(PositionOpened {
            margin_account_id: object::id(account),
            position_id: new_pos_key, 
        });
        new_pos_key
    }

    public fun process_funding_for_position<CollateralAsset>(
        account: &mut MarginAccount<CollateralAsset>,
        position_id: ID, 
        market_cumulative_funding_per_unit: SignedU128, 
        clock: &Clock,
    ) {
        assert!(bag::contains(&account.positions, position_id), EPositionNotFound);
        let pos: &mut Position = bag::borrow_mut(&mut account.positions, position_id);

        let payment = position::calculate_funding_payment(pos, market_cumulative_funding_per_unit);

        if (position::is_negative(&payment)) { // User pays funding
            let amount_to_pay = position::magnitude(&payment) as u64; 
            if (balance::value(&account.collateral) >= amount_to_pay) {
                let paid_balance = balance::split(&mut account.collateral, amount_to_pay);
                balance::destroy_zero(paid_balance); 
            } else {
                assert!(false, EBalanceTooLowToPayFunding); 
            }
        } else { // User receives funding
            let _amount_to_receive = position::magnitude(&payment) as u64; 
            // Placeholder: Correctly handle receiving funds.
        };

        position::update_position_funding_state(pos, market_cumulative_funding_per_unit, clock);
        
        event::emit(FundingPaymentProcessed<CollateralAsset> {
            margin_account_id: object::id(account),
            position_id,
            payment_amount: payment,
        });
    }

    // --- Public-View Functions ---

    public fun total_collateral_value<CollateralAsset>(
        account: &MarginAccount<CollateralAsset>
    ): u64 {
        balance::value(&account.collateral)
    }

    public fun get_position<CollateralAsset>(
        account: &MarginAccount<CollateralAsset>,
        position_id: ID
    ): &Position {
        assert!(bag::contains(&account.positions, position_id), EPositionNotFound);
        bag::borrow(&account.positions, position_id)
    }
} 