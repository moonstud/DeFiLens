;; DeFiHub Analytics Framework - Phase 1
;; Basic DeFi analytics capabilities with STX staking

;; Core Constants
(define-constant controller-wallet tx-sender)
(define-constant ERR-ACCESS-REJECTED (err u3001))
(define-constant ERR-AMOUNT-INVALID (err u3003))
(define-constant ERR-STX-INSUFFICIENT (err u3004))
(define-constant ERR-NO-ENGAGEMENT (err u3006))
(define-constant ERR-BELOW-MINIMUM (err u3007))
(define-constant ERR-PLATFORM-PAUSED (err u3008))

;; Platform Asset Definition
(define-fungible-token ANALYTICS-COIN)

;; Framework Status Variables
(define-data-var platform-paused bool false)

;; Engagement Parameters
(define-data-var stx-pool uint u0)
(define-data-var base-apr uint u500) ;; 5% base rate (100 = 1%)
(define-data-var minimum-stake uint u1000000) ;; Minimum stake amount

;; Basic Data Structures
(define-map UserAnalytics
    principal
    {
        stx-allocated: uint,
        framework-coins: uint,
        tier-level: uint,
        last-update: uint
    }
)

(define-map StakeDetails
    principal
    {
        amount: uint,
        start-block: uint,
        last-harvest: uint
    }
)

;; Framework Initialization
(define-public (initialize-framework)
    (begin
        (asserts! (is-eq tx-sender controller-wallet) ERR-ACCESS-REJECTED)
        (ok true)
    )
)

;; Stake STX
(define-public (stake-stx (amount uint))
    (let
        (
            (current-analytics (default-to 
                {
                    stx-allocated: u0,
                    framework-coins: u0,
                    tier-level: u0,
                    last-update: u0
                }
                (map-get? UserAnalytics tx-sender)))
        )
        (asserts! (not (var-get platform-paused)) ERR-PLATFORM-PAUSED)
        (asserts! (>= amount (var-get minimum-stake)) ERR-BELOW-MINIMUM)
        
        ;; Transfer STX to contract
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        
        ;; Calculate tier
        (let
            (
                (new-total-stake (+ (get stx-allocated current-analytics) amount))
                (tier-level (assess-tier-level new-total-stake))
            )
            
            ;; Update stake details
            (map-set StakeDetails
                tx-sender
                {
                    amount: amount,
                    start-block: block-height,
                    last-harvest: block-height
                }
            )
            
            ;; Update user analytics
            (map-set UserAnalytics
                tx-sender
                (merge current-analytics
                    {
                        stx-allocated: new-total-stake,
                        tier-level: tier-level,
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

;; Unstake STX
(define-public (unstake-stx (amount uint))
    (let
        (
            (current-analytics (default-to 
                {
                    stx-allocated: u0,
                    framework-coins: u0,
                    tier-level: u0,
                    last-update: u0
                }
                (map-get? UserAnalytics tx-sender)))
            (current-staked (get stx-allocated current-analytics))
        )
        (asserts! (not (var-get platform-paused)) ERR-PLATFORM-PAUSED)
        (asserts! (<= amount current-staked) ERR-STX-INSUFFICIENT)
        
        ;; Transfer STX from contract
        (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
        
        ;; Calculate new tier after withdrawal
        (let
            (
                (new-total-stake (- current-staked amount))
                (tier-level (assess-tier-level new-total-stake))
            )
            
            ;; Update user analytics
            (map-set UserAnalytics
                tx-sender
                (merge current-analytics
                    {
                        stx-allocated: new-total-stake,
                        tier-level: tier-level,
                        last-update: block-height
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
                    stx-allocated: u0,
                    framework-coins: u0,
                    tier-level: u0,
                    last-update: u0
                }
                (map-get? UserAnalytics tx-sender)))
            (stake-info (default-to
                {
                    amount: u0,
                    start-block: u0,
                    last-harvest: u0
                }
                (map-get? StakeDetails tx-sender)))
            (blocks-elapsed (- block-height (get last-harvest stake-info)))
            (staked-amount (get stx-allocated current-analytics))
            (tier-level (get tier-level current-analytics))
        )
        (asserts! (> staked-amount u0) ERR-STX-INSUFFICIENT)
        
        ;; Calculate rewards
        (let
            (
                (base-yield (/ (* staked-amount blocks-elapsed (var-get base-apr)) u1000000))
                (adjusted-yield (/ (* base-yield (tier-multiplier tier-level)) u100))
            )
            
            ;; Mint reward tokens
            (try! (ft-mint? ANALYTICS-COIN adjusted-yield tx-sender))
            
            ;; Update stake details
            (map-set StakeDetails
                tx-sender
                (merge stake-info
                    {
                        last-harvest: block-height
                    }
                )
            )
            
            ;; Update user analytics
            (map-set UserAnalytics
                tx-sender
                (merge current-analytics
                    {
                        framework-coins: (+ (get framework-coins current-analytics) adjusted-yield),
                        last-update: block-height
                    }
                )
            )
            
            (ok adjusted-yield)
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

;; Emergency Functions

;; Pause/unpause the framework
(define-public (toggle-platform-status (paused bool))
    (begin
        (asserts! (is-eq tx-sender controller-wallet) ERR-ACCESS-REJECTED)
        (var-set platform-paused paused)
        (ok paused)
    )
)