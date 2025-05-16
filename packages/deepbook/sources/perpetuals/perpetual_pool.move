// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::perpetual_pool {

    use sui::object::{Self, ID, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::clock::Clock;
    use sui::balance::Balance; // For collateral balances
    // use sui::coin::Coin;       // For collateral type - CollateralType phantom is enough for now
    use sui::event;
    use std::option::{Self, Option}; // Corrected import for Option

    use deepbook::book::{Self, Book};
    use deepbook::order_info::{Self as OrderInfoModule, OrderInfo};
    use deepbook::margin_account::{Self, MarginAccount};
    // use deepbook::position::{Self, Position, SignedU128}; // Position not directly handled by pool, but by MarginAccount
    // use deepbook::oracle; // Assuming a generic oracle module/interface
    use deepbook::constants; // Corrected import for constants
    use deepbook::deep_price::{Self as DeepPriceModule, OrderDeepPrice}; 

    // === Errors ===
    const EInsufficientMargin: u64 = 1;
    const EOraclePriceNotAvailable: u64 = 2;
    const EInvalidOrderParameters: u64 = 3;
    const EMaxLeverageExceeded: u64 = 4;
    const EOracleNotSet: u64 = 5;
    const EAdminOnly: u64 = 6;
    const ENotImplemented: u64 = 501;
    // const EDeepPriceFunctionalityNotAvailable: u64 = 502; // Covered by ENotImplemented or direct check

    public struct PerpetualPool<phantom AssetType, phantom CollateralType> has key, store {
        id: UID,
        admin: address, 
        book: Book, 
        tick_size: u64, 
        lot_size: u64,  
        min_order_size: u64, 

        max_leverage: u64, // e.g., 100 for 100x (implies min initial margin rate of 1%)
        initial_margin_rate_bps: u64, // Basis points, e.g., 100 bps = 1%
        maintenance_margin_rate_bps: u64, // Basis points, e.g., 50 bps = 0.5%

        taker_fee_rate_bps: u64, 
        maker_fee_rate_bps: u64, 
        // collected_fees: Balance<CollateralType>, // TODO: Fee collection mechanism

        index_price_oracle_id: Option<ID>, // Optional: Pool might not have an oracle initially
    }

    public struct PerpetualPoolCreated<phantom AssetType, phantom CollateralType> has copy, drop, store {
        pool_id: ID,
        admin: address,
        tick_size: u64,
        lot_size: u64,
    }

    public struct OrderPlacementInfo has copy, drop, store {
        pool_id: ID,
        margin_account_id: ID,
        order_id: u128, 
        client_order_id: u64, 
        price: u64,
        quantity: u64,
        is_bid: bool,
        timestamp: u64,
    }

    // TODO: TradeExecuted event with more details

    public fun new_perpetual_pool<AssetType, CollateralType>(
        admin: address,
        tick_size: u64,
        lot_size: u64,
        min_order_size: u64,
        max_leverage: u64,
        initial_margin_rate_bps: u64, 
        maintenance_margin_rate_bps: u64, 
        taker_fee_rate_bps: u64,
        maker_fee_rate_bps: u64,
        ctx: &mut TxContext
    ): PerpetualPool<AssetType, CollateralType> {
        assert!(tick_size > 0 && lot_size > 0 && min_order_size >= lot_size, EInvalidOrderParameters);
        assert!(max_leverage > 0, EInvalidOrderParameters); // e.g. 1 for 1x, up to 100 for 100x
        assert!(initial_margin_rate_bps > 0 && initial_margin_rate_bps <= 10000, EInvalidOrderParameters); // 10000bps = 100%
        assert!(maintenance_margin_rate_bps > 0 && maintenance_margin_rate_bps < initial_margin_rate_bps, EInvalidOrderParameters);
        // 1 / max_leverage should be <= initial_margin_rate (e.g. 1/100 <= 1%) 
        // (10000 / max_leverage) <= initial_margin_rate_bps
        assert!((10000 / max_leverage) <= initial_margin_rate_bps, EInvalidOrderParameters); 

        let pool_uid = object::new(ctx);
        let pool = PerpetualPool<AssetType, CollateralType> {
            id: pool_uid,
            admin,
            book: book::empty(tick_size, lot_size, min_order_size, ctx),
            tick_size,
            lot_size,
            min_order_size,
            max_leverage,
            initial_margin_rate_bps,
            maintenance_margin_rate_bps,
            taker_fee_rate_bps,
            maker_fee_rate_bps,
            index_price_oracle_id: std::option::none<ID>(), 
        };

        event::emit(PerpetualPoolCreated<AssetType, CollateralType> {
            pool_id: object::uid_to_inner(&pool.id),
            admin,
            tick_size,
            lot_size,
        });
        pool
    }

    public fun set_oracle_id<AssetType, CollateralType>(
        pool: &mut PerpetualPool<AssetType, CollateralType>,
        oracle_id: ID,
        ctx: &TxContext
    ) {
        assert!(tx_context::sender(ctx) == pool.admin, EAdminOnly);
        pool.index_price_oracle_id = std::option::some(oracle_id);
    }

    // --- Public-Mutative Functions: Trading ---

    public fun place_limit_order<AssetType, CollateralType>(
        pool: &mut PerpetualPool<AssetType, CollateralType>,
        margin_account: &mut MarginAccount<CollateralType>,
        leverage: u64, // User specifies desired leverage for this order/position
        price: u64,    
        quantity: u64, 
        is_bid: bool,  
        client_order_id: u64,
        self_matching_option: u8, // e.g., constants::cancel_aggressor(), constants::cancel_passive()
        expire_timestamp: u64, 
        clock: &Clock,
        ctx: &mut TxContext
    ): u128 /* order_id */ {
        assert!(price % pool.tick_size == 0 && price > 0, EInvalidOrderParameters);
        assert!(quantity % pool.lot_size == 0 && quantity >= pool.min_order_size, EInvalidOrderParameters);
        assert!(leverage > 0 && leverage <= pool.max_leverage, EMaxLeverageExceeded);

        // Calculate required initial margin for this order
        // Notional value = quantity * price (needs scaling if price is not a raw u64)
        // Assume price is already scaled appropriately (e.g., by 10^9)
        // Assume quantity is in base units (e.g., 0.1 SUI = 100,000,000 if SUI has 9 decimals)
        // For simplicity, let quantity be actual number of contracts, and price be price per contract.
        let notional_value = (quantity as u128) * (price as u128);
        // Required margin = Notional / Leverage. 
        // Or, Required margin = Notional * (pool.initial_margin_rate_bps / 10000)
        // User-specified leverage must be respected, and must imply a margin rate >= pool.initial_margin_rate_bps.
        // Effective margin rate from leverage = 1 / leverage.
        // So, (10000 / leverage) must be >= pool.initial_margin_rate_bps.
        assert!((10000 / leverage) >= pool.initial_margin_rate_bps, EMaxLeverageExceeded); // Stricter check based on leverage

        let required_margin_scaled = notional_value / (leverage as u128);

        // TODO: CRITICAL: Implement margin_account::allocate_margin_for_order(...) and call it here.
        // The following line is commented out as the function is not yet implemented in margin_account.move:
        // margin_account::allocate_margin_for_order(margin_account, required_margin_scaled as u64, ctx);
        assert!(false, ENotImplemented); // Margin check and allocation logic is critical and not implemented.

        // Create OrderInfo for the book
        let fee_details_placeholder = DeepPriceModule::new_order_deep_price(false, 0);

        let order_info = OrderInfoModule::new(
            object::uid_to_inner(&pool.id),
            object::id(margin_account), 
            client_order_id,
            tx_context::sender(ctx),
            constants::post_only(), // Corrected: Using constants::post_only()
            self_matching_option,
            price,
            quantity,
            is_bid,
            false, // pay_with_deep
            tx_context::epoch(ctx), // Corrected: epoch from TxContext
            expire_timestamp,
            fee_details_placeholder, // order_deep_price
            false, // market_order
            sui::clock::timestamp_ms(clock),
        );

        // Placeholder for actual book interaction and fill handling
        // let actual_order_id = pool.book.create_order(&mut order_info, sui::clock::timestamp_ms(clock)); 

        let dummy_order_id = 0u128;
        event::emit(OrderPlacementInfo {
            pool_id: object::uid_to_inner(&pool.id),
            margin_account_id: object::id(margin_account),
            order_id: dummy_order_id, 
            client_order_id,
            price,
            quantity,
            is_bid,
            timestamp: sui::clock::timestamp_ms(clock),
        });

        dummy_order_id
    }
    // ... (rest of the module)
} 