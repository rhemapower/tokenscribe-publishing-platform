;; TokenScribe Smart Contract
;; A decentralized publishing platform for e-books on the Stacks blockchain
;; Authors can publish books, set prices, and receive royalties
;; Readers can purchase, own, resell, and review books

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u1001))
(define-constant ERR-BOOK-NOT-FOUND (err u1002))
(define-constant ERR-INSUFFICIENT-FUNDS (err u1003))
(define-constant ERR-ALREADY-PUBLISHED (err u1004))
(define-constant ERR-NOT-OWNER (err u1005))
(define-constant ERR-RESALE-NOT-ALLOWED (err u1006))
(define-constant ERR-INVALID-PRICE (err u1007))
(define-constant ERR-SELF-PURCHASE (err u1008))
(define-constant ERR-LENDING-ACTIVE (err u1009))
(define-constant ERR-NOT-LENT-TO-YOU (err u1010))
(define-constant ERR-ALREADY-REVIEWED (err u1011))
(define-constant ERR-INVALID-RATING (err u1012))
(define-constant ERR-ALREADY-SUBSCRIBED (err u1013))
(define-constant ERR-SUBSCRIPTION-NOT-FOUND (err u1014))

;; Constants
(define-constant DEFAULT-ROYALTY-PERCENTAGE u150) ;; 15.0% as basis points
(define-constant MAX-ROYALTY-PERCENTAGE u300)     ;; 30.0% max
(define-constant MIN-BOOK-PRICE u1000000)         ;; 1 STX minimum price
(define-constant CONTRACT-OWNER tx-sender)         ;; Contract deployer

;; Data structures
;; Book metadata and ownership information
(define-map books
  { book-id: uint }
  {
    title: (string-ascii 256),
    description: (string-utf8 1000),
    cover-image-url: (string-utf8 256),
    content-hash: (buff 32),            ;; Hash of the encrypted book content
    author: principal,
    current-owner: principal,
    price: uint,                        ;; In microSTX
    royalty-percentage: uint,           ;; In basis points (e.g., 150 = 15.0%)
    published-at: uint,                 ;; Block height
    resale-allowed: bool,
    lent-to: (optional principal),      ;; If book is currently lent out
    lending-expiry: (optional uint)     ;; Block height when lending expires
  }
)

;; Track the books published by each author
(define-map author-books
  { author: principal }
  { book-ids: (list 100 uint) }
)

;; Track the books owned by each reader
(define-map reader-books
  { reader: principal }
  { book-ids: (list 100 uint) }
)

;; Track book reviews
(define-map book-reviews
  { book-id: uint, reviewer: principal }
  {
    rating: uint,             ;; 1-5 stars (as uint 1-5)
    review-text: (string-utf8 500),
    review-date: uint         ;; Block height
  }
)

;; Aggregate book ratings
(define-map book-ratings
  { book-id: uint }
  {
    total-ratings: uint,
    sum-ratings: uint,        ;; Sum of all ratings to calculate average
    review-count: uint
  }
)

;; Author subscriptions
(define-map author-subscriptions
  { author: principal }
  {
    price: uint,              ;; Monthly subscription price in microSTX
    description: (string-utf8 500),
    subscriber-count: uint
  }
)

;; Reader subscriptions
(define-map reader-subscriptions
  { reader: principal, author: principal }
  {
    subscribed-at: uint,      ;; Block height
    expires-at: uint          ;; Block height when subscription expires
  }
)

;; Counter for generating unique book IDs
(define-data-var next-book-id uint u1)

;; Private functions
;; Helper to get the next available book ID
(define-private (get-next-book-id)
  (let ((current-id (var-get next-book-id)))
    (var-set next-book-id (+ current-id u1))
    current-id
  )
)

;; Helper to add a book ID to a list
(define-private (add-book-to-list (book-id uint) (existing-list (list 100 uint)))
  (if (> (len existing-list) u99)
    existing-list ;; List is full, don't add more
    (append existing-list book-id)
  )
)

;; Helper to check if book exists
(define-private (is-book-exists (book-id uint))
  (is-some (map-get? books {book-id: book-id}))
)

;; Helper to check if sender is the book owner
(define-private (is-owner (book-id uint))
  (let ((book-info (unwrap! (map-get? books {book-id: book-id}) false)))
    (is-eq tx-sender (get current-owner book-info))
  )
)

;; Helper to check if sender is the book author
(define-private (is-author (book-id uint))
  (let ((book-info (unwrap! (map-get? books {book-id: book-id}) false)))
    (is-eq tx-sender (get author book-info))
  )
)

;; Helper to check if a book can be transferred
(define-private (can-transfer-book (book-id uint))
  (let ((book-info (unwrap! (map-get? books {book-id: book-id}) false)))
    (and 
      (is-owner book-id) 
      (is-none (get lent-to book-info))
    )
  )
)

;; Helper to calculate author royalty
(define-private (calculate-royalty (price uint) (royalty-percentage uint))
  (/ (* price royalty-percentage) u1000)
)

;; Helper to update reader's book list when they acquire a book
(define-private (add-book-to-reader (reader principal) (book-id uint))
  (let ((current-books (default-to {book-ids: (list)} (map-get? reader-books {reader: reader}))))
    (map-set reader-books
      {reader: reader}
      {book-ids: (add-book-to-list book-id (get book-ids current-books))}
    )
  )
)

;; Helper to check if user has access to a book
(define-private (has-book-access (book-id uint) (user principal))
  (let ((book-info (unwrap! (map-get? books {book-id: book-id}) false)))
    (or
      (is-eq user (get current-owner book-info))
      (is-eq (some user) (get lent-to book-info))
      (is-eq user (get author book-info))
    )
  )
)

;; Read-only functions
;; Get book details (public metadata)
(define-read-only (get-book-public-details (book-id uint))
  (let ((book-info (unwrap! (map-get? books {book-id: book-id}) ERR-BOOK-NOT-FOUND)))
    (ok {
      title: (get title book-info),
      description: (get description book-info),
      cover-image-url: (get cover-image-url book-info),
      author: (get author book-info),
      price: (get price book-info),
      royalty-percentage: (get royalty-percentage book-info),
      published-at: (get published-at book-info),
      resale-allowed: (get resale-allowed book-info)
    })
  )
)

;; Get book content hash (only accessible by current owner or borrower)
(define-read-only (get-book-content-hash (book-id uint))
  (let ((book-info (unwrap! (map-get? books {book-id: book-id}) ERR-BOOK-NOT-FOUND)))
    (if (has-book-access book-id tx-sender)
      (ok (get content-hash book-info))
      ERR-NOT-AUTHORIZED
    )
  )
)

;; Check if user has access to a book
(define-read-only (check-book-access (book-id uint))
  (if (is-book-exists book-id)
    (ok (has-book-access book-id tx-sender))
    ERR-BOOK-NOT-FOUND
  )
)

;; Get all books by an author
(define-read-only (get-author-books (author principal))
  (ok (default-to {book-ids: (list)} (map-get? author-books {author: author})))
)

;; Get all books owned by a reader
(define-read-only (get-reader-books (reader principal))
  (ok (default-to {book-ids: (list)} (map-get? reader-books {reader: reader})))
)

;; Get book rating information
(define-read-only (get-book-rating (book-id uint))
  (let ((rating-info (default-to {total-ratings: u0, sum-ratings: u0, review-count: u0} 
                     (map-get? book-ratings {book-id: book-id}))))
    (ok rating-info)
  )
)

;; Check if a user has a subscription to an author
(define-read-only (check-subscription (reader principal) (author principal))
  (let ((subscription (map-get? reader-subscriptions {reader: reader, author: author})))
    (if (is-some subscription)
      (let ((sub-info (unwrap-panic subscription)))
        (if (< (get expires-at sub-info) block-height)
          (ok false) ;; Subscription expired
          (ok true)  ;; Active subscription
        )
      )
      (ok false)     ;; No subscription
    )
  )
)

;; Public functions
;; Publish a new book
(define-public (publish-book 
  (title (string-ascii 256))
  (description (string-utf8 1000))
  (cover-image-url (string-utf8 256))
  (content-hash (buff 32))
  (price uint)
  (royalty-percentage uint)
  (resale-allowed bool)
)
  (let (
    (author tx-sender)
    (book-id (get-next-book-id))
    (current-books (default-to {book-ids: (list)} (map-get? author-books {author: author})))
  )
    ;; Validate inputs
    (asserts! (>= price MIN-BOOK-PRICE) ERR-INVALID-PRICE)
    (asserts! (<= royalty-percentage MAX-ROYALTY-PERCENTAGE) ERR-INVALID-PRICE)
    
    ;; Create the book record
    (map-set books 
      {book-id: book-id}
      {
        title: title,
        description: description,
        cover-image-url: cover-image-url,
        content-hash: content-hash,
        author: author,
        current-owner: author, ;; Author is the initial owner
        price: price,
        royalty-percentage: (if (> royalty-percentage u0) 
                               royalty-percentage 
                               DEFAULT-ROYALTY-PERCENTAGE),
        published-at: block-height,
        resale-allowed: resale-allowed,
        lent-to: none,
        lending-expiry: none
      }
    )
    
    ;; Update author's book list
    (map-set author-books
      {author: author}
      {book-ids: (add-book-to-list book-id (get book-ids current-books))}
    )
    
    ;; Add to author's owned books too
    (add-book-to-reader author book-id)
    
    ;; Initialize rating entry
    (map-set book-ratings
      {book-id: book-id}
      {total-ratings: u0, sum-ratings: u0, review-count: u0}
    )
    
    (ok book-id)
  )
)

;; Purchase a book
(define-public (purchase-book (book-id uint))
  (let (
    (book-info (unwrap! (map-get? books {book-id: book-id}) ERR-BOOK-NOT-FOUND))
    (buyer tx-sender)
    (seller (get current-owner book-info))
    (author (get author book-info))
    (price (get price book-info))
  )
    ;; Check that buyer is not already the owner
    (asserts! (not (is-eq buyer seller)) ERR-SELF-PURCHASE)
    
    ;; Check that the book is not currently being lent
    (asserts! (is-none (get lent-to book-info)) ERR-LENDING-ACTIVE)
    
    ;; If seller is not the author, verify resale is allowed
    (asserts! (or (is-eq seller author) (get resale-allowed book-info)) ERR-RESALE-NOT-ALLOWED)
    
    ;; Handle the payment differently based on whether this is a first sale or resale
    (if (is-eq seller author)
      ;; First sale - author gets full amount
      (begin
        (try! (stx-transfer? price buyer author))
        
        ;; Update book ownership
        (map-set books
          {book-id: book-id}
          (merge book-info {current-owner: buyer, lent-to: none, lending-expiry: none})
        )
        
        ;; Add to buyer's book list
        (add-book-to-reader buyer book-id)
        
        (ok true)
      )
      ;; Resale - split between seller and author (royalties)
      (let (
        (royalty-amount (calculate-royalty price (get royalty-percentage book-info)))
        (seller-amount (- price royalty-amount))
      )
        ;; Transfer royalty to author
        (try! (stx-transfer? royalty-amount buyer author))
        
        ;; Transfer remaining amount to seller
        (try! (stx-transfer? seller-amount buyer seller))
        
        ;; Update book ownership
        (map-set books
          {book-id: book-id}
          (merge book-info {current-owner: buyer, lent-to: none, lending-expiry: none})
        )
        
        ;; Add to buyer's book list
        (add-book-to-reader buyer book-id)
        
        (ok true)
      )
    )
  )
)

;; Update book price (only current owner)
(define-public (update-book-price (book-id uint) (new-price uint))
  (let ((book-info (unwrap! (map-get? books {book-id: book-id}) ERR-BOOK-NOT-FOUND)))
    ;; Verify sender is the owner
    (asserts! (is-owner book-id) ERR-NOT-OWNER)
    
    ;; Validate new price
    (asserts! (>= new-price MIN-BOOK-PRICE) ERR-INVALID-PRICE)
    
    ;; Update the price
    (map-set books
      {book-id: book-id}
      (merge book-info {price: new-price})
    )
    
    (ok true)
  )
)

;; Toggle resale permission (only author)
(define-public (toggle-resale-permission (book-id uint))
  (let ((book-info (unwrap! (map-get? books {book-id: book-id}) ERR-BOOK-NOT-FOUND)))
    ;; Verify sender is the author
    (asserts! (is-author book-id) ERR-NOT-AUTHORIZED)
    
    ;; Toggle the resale permission
    (map-set books
      {book-id: book-id}
      (merge book-info {resale-allowed: (not (get resale-allowed book-info))})
    )
    
    (ok (not (get resale-allowed book-info)))
  )
)

;; Lend a book to a friend for a limited time
(define-public (lend-book (book-id uint) (borrower principal) (duration uint))
  (let (
    (book-info (unwrap! (map-get? books {book-id: book-id}) ERR-BOOK-NOT-FOUND))
    (expiry-height (+ block-height duration))
  )
    ;; Verify sender is the owner
    (asserts! (is-owner book-id) ERR-NOT-OWNER)
    
    ;; Verify book is not already lent out
    (asserts! (is-none (get lent-to book-info)) ERR-LENDING-ACTIVE)
    
    ;; Update lending information
    (map-set books
      {book-id: book-id}
      (merge book-info 
        {
          lent-to: (some borrower),
          lending-expiry: (some expiry-height)
        }
      )
    )
    
    (ok expiry-height)
  )
)

;; Return a borrowed book early
(define-public (return-book (book-id uint))
  (let ((book-info (unwrap! (map-get? books {book-id: book-id}) ERR-BOOK-NOT-FOUND)))
    ;; Verify the book is currently lent to the sender
    (asserts! (is-eq (some tx-sender) (get lent-to book-info)) ERR-NOT-LENT-TO-YOU)
    
    ;; Update lending information
    (map-set books
      {book-id: book-id}
      (merge book-info 
        {
          lent-to: none,
          lending-expiry: none
        }
      )
    )
    
    (ok true)
  )
)

;; Leave a review for a book (only if you own or have owned it)
(define-public (review-book (book-id uint) (rating uint) (review-text (string-utf8 500)))
  (let (
    (book-info (unwrap! (map-get? books {book-id: book-id}) ERR-BOOK-NOT-FOUND))
    (current-ratings (default-to 
                       {total-ratings: u0, sum-ratings: u0, review-count: u0}
                       (map-get? book-ratings {book-id: book-id})))
  )
    ;; Verify rating is between 1-5
    (asserts! (and (>= rating u1) (<= rating u5)) ERR-INVALID-RATING)
    
    ;; Verify user has access to the book
    (asserts! (has-book-access book-id tx-sender) ERR-NOT-AUTHORIZED)
    
    ;; Check if user has already reviewed this book
    (asserts! (is-none (map-get? book-reviews {book-id: book-id, reviewer: tx-sender})) ERR-ALREADY-REVIEWED)
    
    ;; Add the review
    (map-set book-reviews
      {book-id: book-id, reviewer: tx-sender}
      {
        rating: rating,
        review-text: review-text,
        review-date: block-height
      }
    )
    
    ;; Update aggregate ratings
    (map-set book-ratings
      {book-id: book-id}
      {
        total-ratings: (+ (get total-ratings current-ratings) u1),
        sum-ratings: (+ (get sum-ratings current-ratings) rating),
        review-count: (+ (get review-count current-ratings) u1)
      }
    )
    
    (ok true)
  )
)

;; Create an author subscription option
(define-public (create-subscription (price uint) (description (string-utf8 500)))
  (let ((author tx-sender))
    ;; Validate price
    (asserts! (> price u0) ERR-INVALID-PRICE)
    
    ;; Set up subscription details
    (map-set author-subscriptions
      {author: author}
      {
        price: price,
        description: description,
        subscriber-count: u0
      }
    )
    
    (ok true)
  )
)

;; Subscribe to an author (one month duration)
(define-public (subscribe-to-author (author principal))
  (let (
    (subscription (unwrap! (map-get? author-subscriptions {author: author}) ERR-SUBSCRIPTION-NOT-FOUND))
    (reader tx-sender)
    (price (get price subscription))
    (expiry-height (+ block-height u4380)) ;; ~30 days (assuming 10-min blocks)
    (current-subscription (map-get? reader-subscriptions {reader: reader, author: author}))
  )
    ;; Check if already subscribed
    (when (is-some current-subscription)
      (let ((sub-info (unwrap-panic current-subscription)))
        (asserts! (< (get expires-at sub-info) block-height) ERR-ALREADY-SUBSCRIBED)
      )
    )
    
    ;; Process payment
    (try! (stx-transfer? price reader author))
    
    ;; Create subscription
    (map-set reader-subscriptions
      {reader: reader, author: author}
      {
        subscribed-at: block-height,
        expires-at: expiry-height
      }
    )
    
    ;; Increment subscriber count
    (map-set author-subscriptions
      {author: author}
      (merge subscription {subscriber-count: (+ (get subscriber-count subscription) u1)})
    )
    
    (ok expiry-height)
  )
)