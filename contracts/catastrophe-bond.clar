;; Catastrophe Bond Contract
;; Manages tokenized catastrophe bonds with automated triggers

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u400))
(define-constant ERR-BOND-EXISTS (err u401))
(define-constant ERR-BOND-NOT-FOUND (err u402))
(define-constant ERR-INVALID-INPUT (err u403))
(define-constant ERR-INSUFFICIENT-FUNDS (err u404))
(define-constant ERR-BOND-MATURED (err u405))
(define-constant ERR-TRIGGER-ACTIVATED (err u406))

;; Data Variables
(define-data-var bond-counter uint u0)

;; Data Maps
(define-map catastrophe-bonds
  { bond-id: uint }
  {
    issuer: principal,
    bond-name: (string-ascii 50),
    principal-amount: uint,
    coupon-rate: uint,
    maturity-blocks: uint,
    issue-block: uint,
    trigger-threshold: uint,
    current-trigger-value: uint,
    is-active: bool,
    is-triggered: bool,
    total-issued: uint,
    total-outstanding: uint
  }
)

(define-map bond-holders
  { bond-id: uint, holder: principal }
  {
    amount-held: uint,
    purchase-block: uint,
    last-coupon-payment: uint
  }
)

(define-map trigger-events
  { bond-id: uint, event-id: uint }
  {
    event-type: (string-ascii 30),
    event-value: uint,
    reported-block: uint,
    verified: bool
  }
)

(define-map coupon-payments
  { bond-id: uint, payment-period: uint }
  {
    payment-amount: uint,
    payment-block: uint,
    total-recipients: uint
  }
)

;; Public Functions

;; Create new catastrophe bond
(define-public (create-bond
    (bond-name (string-ascii 50))
    (principal-amount uint)
    (coupon-rate uint)
    (maturity-blocks uint)
    (trigger-threshold uint))
  (let
    (
      (bond-id (+ (var-get bond-counter) u1))
    )
    (asserts! (> principal-amount u0) ERR-INVALID-INPUT)
    (asserts! (< coupon-rate u1000) ERR-INVALID-INPUT)
    (asserts! (> maturity-blocks u0) ERR-INVALID-INPUT)
    (asserts! (> trigger-threshold u0) ERR-INVALID-INPUT)
    (asserts! (is-none (map-get? catastrophe-bonds { bond-id: bond-id })) ERR-BOND-EXISTS)

    (map-set catastrophe-bonds
      { bond-id: bond-id }
      {
        issuer: tx-sender,
        bond-name: bond-name,
        principal-amount: principal-amount,
        coupon-rate: coupon-rate,
        maturity-blocks: maturity-blocks,
        issue-block: block-height,
        trigger-threshold: trigger-threshold,
        current-trigger-value: u0,
        is-active: true,
        is-triggered: false,
        total-issued: u0,
        total-outstanding: u0
      }
    )
    (var-set bond-counter bond-id)
    (ok bond-id)
  )
)

;; Purchase bond tokens
(define-public (purchase-bond (bond-id uint) (amount uint))
  (let
    (
      (bond (unwrap! (map-get? catastrophe-bonds { bond-id: bond-id }) ERR-BOND-NOT-FOUND))
      (existing-holding (default-to { amount-held: u0, purchase-block: u0, last-coupon-payment: u0 }
                          (map-get? bond-holders { bond-id: bond-id, holder: tx-sender })))
    )
    (asserts! (> amount u0) ERR-INVALID-INPUT)
    (asserts! (get is-active bond) ERR-NOT-AUTHORIZED)
    (asserts! (not (get is-triggered bond)) ERR-TRIGGER-ACTIVATED)
    (asserts! (<= (+ (get total-outstanding bond) amount) (get principal-amount bond)) ERR-INSUFFICIENT-FUNDS)

    (map-set bond-holders
      { bond-id: bond-id, holder: tx-sender }
      {
        amount-held: (+ (get amount-held existing-holding) amount),
        purchase-block: block-height,
        last-coupon-payment: block-height
      }
    )

    (map-set catastrophe-bonds
      { bond-id: bond-id }
      (merge bond {
        total-issued: (+ (get total-issued bond) amount),
        total-outstanding: (+ (get total-outstanding bond) amount)
      })
    )
    (ok true)
  )
)

;; Report trigger event
(define-public (report-trigger-event (bond-id uint) (event-id uint) (event-type (string-ascii 30)) (event-value uint))
  (let
    (
      (bond (unwrap! (map-get? catastrophe-bonds { bond-id: bond-id }) ERR-BOND-NOT-FOUND))
    )
    (asserts! (get is-active bond) ERR-NOT-AUTHORIZED)
    (asserts! (not (get is-triggered bond)) ERR-TRIGGER-ACTIVATED)
    (asserts! (> event-value u0) ERR-INVALID-INPUT)

    (map-set trigger-events
      { bond-id: bond-id, event-id: event-id }
      {
        event-type: event-type,
        event-value: event-value,
        reported-block: block-height,
        verified: false
      }
    )

    ;; Update current trigger value
    (map-set catastrophe-bonds
      { bond-id: bond-id }
      (merge bond { current-trigger-value: event-value })
    )

    ;; Check if trigger threshold is exceeded
    (if (>= event-value (get trigger-threshold bond))
      (begin
        (map-set catastrophe-bonds
          { bond-id: bond-id }
          (merge bond { is-triggered: true })
        )
        (ok "trigger-activated")
      )
      (ok "event-recorded")
    )
  )
)

;; Pay coupon to bondholders
(define-public (pay-coupon (bond-id uint) (payment-period uint))
  (let
    (
      (bond (unwrap! (map-get? catastrophe-bonds { bond-id: bond-id }) ERR-BOND-NOT-FOUND))
      (coupon-amount (/ (* (get total-outstanding bond) (get coupon-rate bond)) u10000))
    )
    (asserts! (is-eq tx-sender (get issuer bond)) ERR-NOT-AUTHORIZED)
    (asserts! (get is-active bond) ERR-NOT-AUTHORIZED)
    (asserts! (not (get is-triggered bond)) ERR-TRIGGER-ACTIVATED)

    (map-set coupon-payments
      { bond-id: bond-id, payment-period: payment-period }
      {
        payment-amount: coupon-amount,
        payment-block: block-height,
        total-recipients: u1
      }
    )
    (ok coupon-amount)
  )
)

;; Redeem bond at maturity
(define-public (redeem-bond (bond-id uint))
  (let
    (
      (bond (unwrap! (map-get? catastrophe-bonds { bond-id: bond-id }) ERR-BOND-NOT-FOUND))
      (holding (unwrap! (map-get? bond-holders { bond-id: bond-id, holder: tx-sender }) ERR-NOT-AUTHORIZED))
      (maturity-block (+ (get issue-block bond) (get maturity-blocks bond)))
    )
    (asserts! (>= block-height maturity-block) ERR-BOND-MATURED)
    (asserts! (> (get amount-held holding) u0) ERR-INSUFFICIENT-FUNDS)
    (asserts! (not (get is-triggered bond)) ERR-TRIGGER-ACTIVATED)

    (map-delete bond-holders { bond-id: bond-id, holder: tx-sender })

    (map-set catastrophe-bonds
      { bond-id: bond-id }
      (merge bond { total-outstanding: (- (get total-outstanding bond) (get amount-held holding)) })
    )
    (ok (get amount-held holding))
  )
)

;; Read-only Functions

;; Get bond details
(define-read-only (get-bond (bond-id uint))
  (map-get? catastrophe-bonds { bond-id: bond-id })
)

;; Get bondholder information
(define-read-only (get-bond-holding (bond-id uint) (holder principal))
  (map-get? bond-holders { bond-id: bond-id, holder: holder })
)

;; Get trigger event details
(define-read-only (get-trigger-event (bond-id uint) (event-id uint))
  (map-get? trigger-events { bond-id: bond-id, event-id: event-id })
)

;; Check if bond is triggered
(define-read-only (is-bond-triggered (bond-id uint))
  (match (map-get? catastrophe-bonds { bond-id: bond-id })
    bond (get is-triggered bond)
    false
  )
)

;; Calculate current yield
(define-read-only (calculate-yield (bond-id uint))
  (match (map-get? catastrophe-bonds { bond-id: bond-id })
    bond
      (if (get is-triggered bond)
        (ok u0)
        (ok (get coupon-rate bond))
      )
    ERR-BOND-NOT-FOUND
  )
)

;; Get bond count
(define-read-only (get-bond-count)
  (var-get bond-counter)
)
