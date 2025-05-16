// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// Module for perpetual futures position management
module deepbook::position {

    use sui::balance::{Self, Balance};
    use sui::object::{Self, ID, UID};
    use sui::clock::{Self, Clock};
    use sui::tx_context::{Self, TxContext};
    // use sui::math; // Not directly used for abs_diff currently

    /// Represents a signed u128 value.
    public struct SignedU128 has copy, drop, store {
        magnitude: u128,
        is_negative: bool,
    }

    public fun new_signed_u128(value: u128, is_negative: bool): SignedU128 {
        SignedU128 { magnitude: value, is_negative }
    }

    public fun magnitude(s: &SignedU128): u128 {
        s.magnitude
    }

    public fun is_negative(s: &SignedU128): bool {
        s.is_negative
    }

    // Placeholder for the actual collateral asset type, e.g., USDC
    // For now, we can use a generic, but eventually, it might be tied to specific collateral types.
    // Alternatively, the MarginAccount can be generic over CollateralAsset.
    // For simplicity in this draft, let's assume the collateral type is handled by the MarginAccount.

    /// Represents an open perpetual futures position for a user.
    /// This struct would typically be stored within a user's MarginAccount.
    public struct Position has store, key {
        id: UID, // Unique identifier for this position object
        owner_account_id: ID, // ID of the MarginAccount that owns this position

        // Market Identification
        // Could be an ID of a PerpetualMarket object or specific asset identifiers
        // For now, using generic types, assuming PerpetualPool will define these.
        // base_asset_type: TypeName, // e.g., "BTC" - represented by its type
        // quote_asset_type: TypeName, // e.g., "USD" - conceptual, as perps are quoted in a stablecoin

        // Position Details
        is_long: bool, // True if long, false if short
        quantity: u64, // Size of the position in terms of the base asset (e.g., 0.1 BTC)
        entry_price: u64, // Average entry price of the position (scaled, e.g., price * 10^9)
        
        // Margin and Leverage
        collateral_amount: u64, // Amount of collateral initially allocated (scaled) or current conceptual margin.
                                // Actual collateral is held in MarginAccount.
        leverage: u64, // Leverage used for this position (e.g., 10 for 10x) - can be scaled (e.g. 10_000 for 10.00x)

        // State Tracking
        cumulative_funding_per_unit: SignedU128, // The cumulative funding rate per unit of the asset when the position was last updated or opened.
        last_updated_timestamp_ms: u64, // Timestamp of the last update (e.g., funding, margin change)
        
        // Mark Price at time of opening or last significant update (optional, could be recalculated)
        // mark_price_at_open: u64, 

        // Liquidation price (can be calculated on the fly or stored)
        // liquidation_price: u64, 
    }

    // --- Functions ---

    public fun new_position(
        owner_account_id: ID,
        is_long: bool,
        quantity: u64,
        entry_price: u64,
        collateral_amount: u64,
        leverage: u64,
        initial_cumulative_funding_per_unit: SignedU128,
        timestamp_ms: u64,
        ctx: &mut TxContext
    ): Position {
        Position {
            id: object::new(ctx),
            owner_account_id,
            is_long,
            quantity,
            entry_price,
            collateral_amount,
            leverage,
            cumulative_funding_per_unit: initial_cumulative_funding_per_unit, // Corrected assignment
            last_updated_timestamp_ms: timestamp_ms,
        }
    }

    // Accessor for the Position's UID
    public fun get_uid(pos: &Position): &UID {
        &pos.id
    }

    // Helper to subtract SignedU128 values: a - b. Returns a SignedU128.
    fun sub_signed_u128(a: SignedU128, b: SignedU128): SignedU128 {
        if (a.is_negative == b.is_negative) {
            if (a.magnitude >= b.magnitude) {
                SignedU128 { magnitude: a.magnitude - b.magnitude, is_negative: a.is_negative }
            } else {
                SignedU128 { magnitude: b.magnitude - a.magnitude, is_negative: !a.is_negative }
            }
        } else {
            SignedU128 { magnitude: a.magnitude + b.magnitude, is_negative: a.is_negative }
        }
    }

    /// Calculates the funding payment for a position.
    /// Returns a SignedU128: 
    /// - Positive if the user receives funding.
    /// - Negative if the user pays funding.
    public fun calculate_funding_payment(
        pos: &Position, // Changed to immutable borrow, as it doesn't modify position directly here
        new_cumulative_funding_per_unit: SignedU128 // Global cumulative funding for the market
    ): SignedU128 { 
        let funding_diff_signed = sub_signed_u128(new_cumulative_funding_per_unit, pos.cumulative_funding_per_unit);
        
        // Conceptual: payment_scaled = quantity * funding_diff_signed.magnitude
        let payment_abs_scaled_128 = (pos.quantity as u128) * funding_diff_signed.magnitude;
        
        // Example scaling: assume funding rates and prices are scaled by 10^9 or similar.
        // The actual scaling factor here depends on how `funding_diff_signed.magnitude` is defined (e.g., scaled USD per unit of base asset).
        // Let's assume payment_abs_scaled_128 is the final absolute payment amount, correctly scaled.
        // For this example, let's say no further division for scaling is needed here, assuming funding_diff_signed already incorporates it.
        let payment_abs_value_128 = payment_abs_scaled_128;

        let mut payment_is_negative = false;

        if (pos.is_long) {
            // If funding_diff is positive (new_rate > old_rate), longs pay (payment is negative for user).
            // If funding_diff is negative (new_rate < old_rate), longs receive (payment is positive for user).
            payment_is_negative = !funding_diff_signed.is_negative; 
        } else { // Position is short
            // If funding_diff is positive (new_rate > old_rate), shorts receive (payment is positive for user).
            // If funding_diff is negative (new_rate < old_rate), shorts pay (payment is negative for user).
            payment_is_negative = funding_diff_signed.is_negative; 
        };
        
        SignedU128 { magnitude: payment_abs_value_128, is_negative: payment_is_negative }
    }

    /// Updates the position's funding markers after a funding event.
    /// This should be called by the MarginAccount after processing the payment.
    public fun update_position_funding_state(
        pos_mut: &mut Position,
        new_cumulative_funding_per_unit: SignedU128,
        clock: &Clock,
    ) {
        pos_mut.cumulative_funding_per_unit = new_cumulative_funding_per_unit;
        pos_mut.last_updated_timestamp_ms = clock::timestamp_ms(clock);
    }

    // TODO: Add functions for:
    // - Calculating current P&L (requires mark price from oracle/order book)
    // - Calculating current margin (collateral_amount - unrealized_loss or + unrealized_gain)
    // - Calculating margin ratio (current margin / position_value_at_mark_price)
    // - Checking if margin ratio is below maintenance margin ratio (is_liquidatable)
    // - Calculating liquidation price
    // - Modifying position: 
    //    - increase_collateral
    //    - decrease_collateral (with checks)
    //    - realize_pnl_and_close (fully or partially)
} 