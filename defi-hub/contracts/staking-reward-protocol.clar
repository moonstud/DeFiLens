;; DeFiHub Analytics Framework - Phase 2
;; Enhanced DeFi analytics with time locks and extended features

;; Core Constants
(define-constant controller-wallet tx-sender)
(define-constant ERR-ACCESS-REJECTED (err u3001))
(define-constant ERR-NETWORK-INCOMPATIBLE (err u3002))
(define-constant ERR-AMOUNT-INVALID (err u3003))
(define-constant ERR-STX-INSUFFICIENT (err u3004))
(define-constant ERR-COOLING-PERIOD (err u3005))
(define-constant ERR-NO-ENGAGEMENT (err u3006))
(define-constant ERR-BELOW-MINIMUM (err u3007))
(define-constant ERR-PLATFORM-PAUSED (err u3008))

;; Platform Asset Definition
(define-fungible-token ANALYTICS-COIN)

;; Framework Status Variables
(define-data-var platform-paused bool false)
(define-data-var emergency-mode bool false)

;; Engagement Parameters
(define-data-var stx-pool uint u0)
(define-data-var base-apr uint u500) ;; 5% base rate (100 = 1%)
(define-data-var time-bonus uint u100) ;; 1% extra for extended engagement
(define-data-var minimum-stake uint u1000000) ;; Minimum stake amount
(define-data-var lockup-period uint u1440) ;; 24 hour cooling period in blocks

;; Enhanced Data Structures
(define-map UserAnalytics
    principal
    {
        allocated-resources: uint,
        health-coefficient: uint,
        last-update: uint,
        stx-allocated: uint,
        framework-coins: uint,
        tier-level: uint,
        reward-multiplier: uint
    }
)

(define-map StakeDetails
    principal
    {
        amount: uint,
        start-block: uint,
        last-harvest: uint,
        lock-timeframe: uint,
        withdrawal-timer: (optional uint),
        unclaimed-rewards: uint
    }
)

(define-map TierLevels
    uint  ;; tier level
    {
        minimum-requirement: uint,
        tier-multiplier: uint,
        feature-access: (list 3 bool)
    }
)

;; Network Configuration
(define-map SupportedNetworks
    (string-ascii 20)
    {
        enabled: bool,
        risk-coefficient: uint,
        reward-rate: uint
    }
)

;; Framework Initialization
(define-public (initialize-framework)
    (begin
        (asserts! (is-eq tx-sender controller-wallet) ERR-ACCESS-REJECTED)
        
        ;; Configure tier levels
        (map-set TierLevels u1 
            {
                minimum-requirement: u1000000,  ;; 1M uSTX
                tier-multiplier: u100,     ;; 1x
                feature-access: (list true false false)
            })
        (map-set TierLevels u2
            {
                minimum-requirement: u5000000,  ;; 5M uSTX
                tier-multiplier: u150,     ;; 1.5x
                feature-access: (list true true false)
            })
        (map-set TierLevels u3
            {
                minimum-requirement: u10000000, ;; 10M uSTX
                tier-multiplier: u200,     ;; 2x
                feature-access: (list true true true)
            })
            
        ;; Initialize networks
        (map-set SupportedNetworks "btc-chain"
            {
                enabled: true,
                risk-coefficient: u200,
                reward-rate: u300
            }
        )
        
        (ok true)
    )
)

;; Stake STX with optional time lock
(define-public (stake-stx (amount uint) (lock-duration uint))
    (let
        (
            (current-analytics (default-to 
                {
                    allocated-resources: u0,
                    health-coefficient: u0,
                    last-update: u0,
                    stx-allocated: u0,
                    framework-coins: u0,
                    tier-level: u0,
                    reward-multiplier: u100
                }
                (map-get? UserAnalytics tx-sender)))
        )
        (asserts! (not (var-get platform-paused)) ERR-PLATFORM-PAUSED)
        (asserts! (>= amount (var-get minimum-stake)) ERR-BELOW-MINIMUM)
        
        ;; Transfer STX to contract
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        
        ;; Calculate tier and multiplier
        (let
            (
                (new-total-stake (+ (get stx-allocated current-analytics) amount))
                (tier-info (assess-tier-level new-total-stake))
                (duration-bonus (compute-duration-bonus lock-duration))
                (health-calculation (compute-health-coefficient new-total-stake))
            )
            
            ;; Update stake details
            (map-set StakeDetails
                tx-sender
                {
                    amount: amount,
                    start-block: block-height,
                    last-harvest: block-height,
                    lock-timeframe: lock-duration,
                    withdrawal-timer: none,
                    unclaimed-rewards: u0
                }
            )
            
            ;; Update user analytics with new tier data
            (map-set UserAnalytics
                tx-sender
                (merge current-analytics
                    {
                        allocated-resources: new-total-stake,
                        stx-allocated: new-total-stake,
                        health-coefficient: health-calculation,
                        tier-level: tier-info,
                        reward-multiplier: (* (tier-multiplier tier-info) duration-bonus),
                        last-update: block-height
                    }
                )
            )
            
            ;; Update STX pool
            (var-set stx-pool (+ (var-get stx-pool) amount))
            (ok true)
        )
    )
)

;; Initiate unstaking process
(define-public (request-unstake (amount uint))
    (let
        (
            (current-analytics (default-to 
                {
                    allocated-resources: u0,
                    health-coefficient: u0,
                    last-update: u0,
                    stx-allocated: u0,
                    framework-coins: u0,
                    tier-level: u0,
                    reward-multiplier: u100
                }
                (map-get? UserAnalytics tx-sender)))
            (stake-info (default-to
                {
                    amount: u0,
                    start-block: u0,
                    last-harvest: u0,
                    lock-timeframe: u0,
                    withdrawal-timer: none,
                    unclaimed-rewards: u0
                }
                (map-get? StakeDetails tx-sender)))
            (current-staked (get stx-allocated current-analytics))
            (active-timelock (get lock-timeframe stake-info))
        )
        (asserts! (not (var-get platform-paused)) ERR-PLATFORM-PAUSED)
        (asserts! (<= amount current-staked) ERR-STX-INSUFFICIENT)
        
        ;; Check if lock period is over
        (asserts! (<= active-timelock block-height) ERR-COOLING-PERIOD)
        
        ;; Set withdrawal timer
        (map-set StakeDetails
            tx-sender
            (merge stake-info
                {
                    withdrawal-timer: (some block-height)
                }
            )
        )
        
        (ok block-height)
    )
)

;; Complete unstaking after cooling period
(define-public (finalize-unstake (amount uint))
    (let
        (
            (current-analytics (default-to 
                {
                    allocated-resources: u0,
                    health-coefficient: u0,
                    last-update: u0,
                    stx-allocated: u0,
                    framework-coins: u0,
                    tier-level: u0,
                    reward-multiplier: u100
                }
                (map-get? UserAnalytics tx-sender)))
            (stake-info (default-to
                {
                    amount: u0,
                    start-block: u0,
                    last-harvest: u0,
                    lock-timeframe: u0,
                    withdrawal-timer: none,
                    unclaimed-rewards: u0
                }
                (map-get? StakeDetails tx-sender)))
            (current-staked (get stx-allocated current-analytics))
            (unstake-time (get withdrawal-timer stake-info))
        )
        (asserts! (not (var-get platform-paused)) ERR-PLATFORM-PAUSED)
        (asserts! (<= amount current-staked) ERR-STX-INSUFFICIENT)
        (asserts! (is-some unstake-time) ERR-NO-ENGAGEMENT)
        
        ;; Check if cooling period is over
        (asserts! (>= block-height (+ (default-to u0 unstake-time) (var-get lockup-period))) ERR-COOLING-PERIOD)
        
        ;; Transfer STX from contract
        (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
        
        ;; Calculate new tier after withdrawal
        (let
            (
                (new-total-stake (- current-staked amount))
                (tier-info (assess-tier-level new-total-stake))
                (health-calculation (compute-health-coefficient new-total-stake))
            )
            
            ;; Update user analytics with new tier data
            (map-set UserAnalytics
                tx-sender
                (merge current-analytics
                    {
                        allocated-resources: new-total-stake,
                        stx-allocated: new-total-stake,
                        health-coefficient: health-calculation,
                        tier-level: tier-info,
                        reward-multiplier: (tier-multiplier tier-info),
                        last-update: block-height
                    }
                )
            )
            
            ;; Reset withdrawal timer
            (map-set StakeDetails
                tx-sender
                (merge stake-info
                    {
                        withdrawal-timer: none
                    }
                )
            )
            
            ;; Update STX pool
            (var-set stx-pool (- (var-get stx-pool) amount))
            (ok true)
        )
    )
)

;; Harvest rewards based on stake
(define-public (harvest-rewards)
    (let
        (
            (current-analytics (default-to 
                {
                    allocated-resources: u0,
                    health-coefficient: u0,
                    last-update: u0,
                    stx-allocated: u0,
                    framework-coins: u0,
                    tier-level: u0,
                    reward-multiplier: u100
                }
                (map-get? UserAnalytics tx-sender)))
            (stake-info (default-to
                {
                    amount: u0,
                    start-block: u0,
                    last-harvest: u0,
                    lock-timeframe: u0,
                    withdrawal-timer: none,
                    unclaimed-rewards: u0
                }
                (map-get? StakeDetails tx-sender)))
            (blocks-elapsed (- block-height (get last-harvest stake-info)))
            (staked-amount (get stx-allocated current-analytics))
            (reward-multiplier (get reward-multiplier current-analytics))
            (pending (get unclaimed-rewards stake-info))
        )
        (asserts! (> staked-amount u0) ERR-STX-INSUFFICIENT)
        
        ;; Calculate rewards
        (let
            (
                (base-yield (/ (* staked-amount blocks-elapsed (var-get base-apr)) u1000000))
                (adjusted-yield (/ (* base-yield reward-multiplier) u100))
                (total-yield (+ adjusted-yield pending))
            )
            
            ;; Mint reward tokens
            (try! (ft-mint? ANALYTICS-COIN total-yield tx-sender))
            
            ;; Update stake details
            (map-set StakeDetails
                tx-sender
                (merge stake-info
                    {
                        last-harvest: block-height,
                        unclaimed-rewards: u0
                    }
                )
            )
            
            ;; Update user analytics
            (map-set UserAnalytics
                tx-sender
                (merge current-analytics
                    {
                        framework-coins: (+ (get framework-coins current-analytics) total-yield),
                        last-update: block-height
                    }
                )
            )
            
            (ok total-yield)
        )
    )
)

;; Helper Functions

;; Determine tier level based on stake amount
(define-private (assess-tier-level (stake-amount uint))
    (if (>= stake-amount u10000000)
        u3
        (if (>= stake-amount u5000000)
            u2
            u1
        )
    )
)

;; Get tier multiplier
(define-private (tier-multiplier (tier uint))
    (if (is-eq tier u3)
        u200
        (if (is-eq tier u2)
            u150
            u100
        )
    )
)

;; Calculate duration bonus based on lock period
(define-private (compute-duration-bonus (lock-duration uint))
    (if (>= lock-duration u8640)     ;; 2 months
        u150                         ;; 1.5x multiplier
        (if (>= lock-duration u4320) ;; 1 month
            u125                     ;; 1.25x multiplier
            u100                     ;; 1x multiplier (no lock)
        )
    )
)

;; Calculate health coefficient
(define-private (compute-health-coefficient (assets uint))
    (if (> assets u0)
        u10000  ;; Max ratio if assets present
        u0
    )
)

;; Emergency Functions

;; Pause/unpause the framework
(define-public (toggle-platform-status (paused bool))
    (begin
        (asserts! (is-eq tx-sender controller-wallet) ERR-ACCESS-REJECTED)
        (var-set platform-paused paused)
        (ok paused)
    )
)

;; Enable emergency mode
(define-public (toggle-emergency-mode (enabled bool))
    (begin
        (asserts! (is-eq tx-sender controller-wallet) ERR-ACCESS-REJECTED)
        (var-set emergency-mode enabled)
        (ok enabled)
    )
)

;; Admin function to update network settings
(define-public (update-network-config 
    (network-name (string-ascii 20)) 
    (enabled bool) 
    (risk-coefficient uint) 
    (reward-rate uint))
    (begin
        (asserts! (is-eq tx-sender controller-wallet) ERR-ACCESS-REJECTED)
        (map-set SupportedNetworks network-name
            {
                enabled: enabled,
                risk-coefficient: risk-coefficient,
                reward-rate: reward-rate
            }
        )
        (ok true)
    )
)