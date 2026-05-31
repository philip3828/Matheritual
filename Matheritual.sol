// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ███╗   ███╗ █████╗ ████████╗██╗  ██╗███████╗██████╗ ██╗████████╗██╗   ██╗ █████╗ ██╗
 * ████╗ ████║██╔══██╗╚══██╔══╝██║  ██║██╔════╝██╔══██╗██║╚══██╔══╝██║   ██║██╔══██╗██║
 * ██╔████╔██║███████║   ██║   ███████║█████╗  ██████╔╝██║   ██║   ██║   ██║███████║██║
 * ██║╚██╔╝██║██╔══██║   ██║   ██╔══██║██╔══╝  ██╔══██╗██║   ██║   ██║   ██║██╔══██║██║
 * ██║ ╚═╝ ██║██║  ██║   ██║   ██║  ██║███████╗██║  ██║██║   ██║   ╚██████╔╝██║  ██║███████╗
 *
 * @title   Matheritual
 * @notice  On-chain math quiz registry on the Ritual Network.
 *          Players register sessions by paying a RITUAL entry fee,
 *          play off-chain, then submit their final score on-chain.
 *          All session data and player history are permanently stored.
 *
 * @dev     Ritual Network — Chain ID 1979
 *          RPC:      http://rpc.ritualfoundation.org/
 *          Currency: RITUAL
 *          Explorer: http://explorer.ritualfoundation.org/
 *
 * @custom:version 1.0.0
 */
contract Matheritual {

    // ═══════════════════════════════════════════════
    //  CONSTANTS
    // ═══════════════════════════════════════════════

    /// @notice Entry fee per session — 0.0002 RITUAL in wei
    uint256 public constant ENTRY_FEE = 0.0002 ether;

    /// @notice Maximum Discord username length
    uint256 public constant MAX_NAME_LEN = 64;

    /// @notice Questions per difficulty tier
    uint256 public constant TIER_SIZE = 5;

    /// @notice Maximum multiplier stored as ×10 integer (50 = 5.0×)
    uint8 public constant MAX_MULT_X10 = 50;

    // ═══════════════════════════════════════════════
    //  ENUMS
    // ═══════════════════════════════════════════════

    /// @notice The 10 difficulty tiers of Matheritual
    enum Tier {
        WarmUp,       // Q1–5
        Easy,         // Q6–10
        Moderate,     // Q11–15
        Steady,       // Q16–20
        Challenging,  // Q21–25
        Tough,        // Q26–30
        Hard,         // Q31–35
        Intense,      // Q36–40
        Brutal,       // Q41–45
        Extreme       // Q46+
    }

    /// @notice Lifecycle state of a session
    enum Status { Active, Completed, Abandoned }

    // ═══════════════════════════════════════════════
    //  STRUCTS
    // ═══════════════════════════════════════════════

    /**
     * @notice A single game session
     */
    struct Session {
        uint64  globalId;          // Global session ID (1-indexed)
        uint64  playerSessionNum;  // nth session for this player (1-indexed)
        address player;            // Wallet address
        string  discordName;       // Discord username at registration
        uint256 registeredAt;      // Block timestamp of registration
        uint256 startBlock;        // Block number of registration
        uint256 submittedAt;       // Timestamp of score submission (0 if not yet)
        uint256 score;             // Final score (0 until submitted)
        uint32  questionsAnswered; // Correct answers
        uint32  bestStreak;        // Best consecutive streak
        Tier    tierReached;       // Highest tier reached
        uint8   multiplierX10;     // Peak multiplier ×10 (e.g. 25 = 2.5×)
        Status  status;            // Active / Completed / Abandoned
    }

    /**
     * @notice Lifetime stats aggregated per player
     */
    struct PlayerStats {
        uint64  totalSessions;      // All sessions registered
        uint64  completedSessions;  // Sessions with a submitted score
        uint256 highScore;          // Best single-session score ever
        uint256 totalScore;         // Sum of all submitted scores
        uint32  allTimeQuestions;   // Total questions answered across all sessions
        uint32  allTimeStreak;      // Best streak ever across all sessions
        Tier    bestTier;           // Highest tier ever reached
        uint256 totalFeesPaid;      // Total RITUAL paid in entry fees (wei)
        uint256 firstSeen;          // Timestamp of first ever registration
        uint256 lastSeen;           // Timestamp of most recent activity
    }

    /**
     * @notice Global aggregate statistics for the whole game
     */
    struct GlobalStats {
        uint64  totalSessions;          // All sessions ever registered
        uint64  completedSessions;      // Sessions with a submitted score
        uint256 feesCollected;          // Total RITUAL collected (wei)
        uint256 allTimeHighScore;       // Highest score ever recorded
        address allTimeHighPlayer;      // Wallet of the all-time record holder
        uint32  totalQuestionsAnswered; // Sum of all questions across all sessions
        uint256 lastActivity;           // Timestamp of last any action
    }

    // ═══════════════════════════════════════════════
    //  STATE VARIABLES
    // ═══════════════════════════════════════════════

    address public owner;
    address public treasury;
    bool    public paused;

    /// @notice Increments with every new registration (sessions start at ID 1)
    uint64 public sessionCounter;

    /// @notice Global game statistics
    GlobalStats public globals;

    /// @notice globalId → Session
    mapping(uint64 => Session) public sessions;

    /// @notice player → ordered list of their globalIds (oldest first)
    mapping(address => uint64[]) private _playerIds;

    /// @notice player → lifetime aggregated stats
    mapping(address => PlayerStats) public playerStats;

    /// @notice player → their current active session globalId (0 = no active session)
    mapping(address => uint64) public activeSession;

    // ═══════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════

    /**
     * @notice Fired when a player registers a new session
     * @param player      Wallet address
     * @param globalId    Session ID assigned
     * @param discordName Player's Discord handle
     * @param fee         Entry fee paid in wei
     * @param timestamp   Block timestamp
     */
    event SessionRegistered(
        address indexed player,
        uint64  indexed globalId,
        string          discordName,
        uint256         fee,
        uint256         timestamp
    );

    /**
     * @notice Fired when a player submits their final score
     * @param player      Wallet address
     * @param globalId    Session ID
     * @param score       Final score
     * @param questions   Correct answers count
     * @param streak      Best consecutive streak
     * @param tier        Highest tier reached
     * @param multX10     Peak multiplier ×10
     * @param timestamp   Block timestamp
     */
    event ScoreSubmitted(
        address indexed player,
        uint64  indexed globalId,
        uint256         score,
        uint32          questions,
        uint32          streak,
        Tier            tier,
        uint8           multX10,
        uint256         timestamp
    );

    /**
     * @notice Fired when a new all-time high score is set
     */
    event NewHighScore(address indexed player, uint256 score);

    /// @notice Fired on fee withdrawal
    event FeesWithdrawn(address indexed to, uint256 amount);

    /// @notice Fired when treasury address changes
    event TreasurySet(address indexed prev, address indexed next);

    /// @notice Fired when contract is paused or unpaused
    event PauseToggled(bool paused);

    /// @notice Fired when ownership is transferred
    event OwnershipTransferred(address indexed prev, address indexed next);

    // ═══════════════════════════════════════════════
    //  CUSTOM ERRORS
    // ═══════════════════════════════════════════════

    error Unauthorized();
    error IsPaused();
    error InsufficientFee(uint256 sent, uint256 required);
    error InvalidName();
    error AlreadyHasActiveSession(uint64 existingId);
    error NoActiveSession();
    error SessionAlreadyFinished(uint64 id);
    error SessionNotFound(uint64 id);
    error InvalidScore();
    error InvalidQuestions();
    error TransferFailed();
    error ZeroAddress();
    error SessionNotStale();

    // ═══════════════════════════════════════════════
    //  MODIFIERS
    // ═══════════════════════════════════════════════

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    // ═══════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════

    /**
     * @param _treasury Address that receives fee withdrawals
     */
    constructor(address _treasury) {
        if (_treasury == address(0)) revert ZeroAddress();
        owner    = msg.sender;
        treasury = _treasury;
    }

    // ═══════════════════════════════════════════════
    //  REGISTER SESSION
    // ═══════════════════════════════════════════════

    /**
     * @notice Register a new game session by paying the RITUAL entry fee.
     *         A player can only hold one active session at a time.
     *         Any RITUAL sent above ENTRY_FEE is refunded immediately.
     *
     * @param discordName  The player's Discord handle (non-empty, max 64 chars)
     * @return id          The global session ID assigned to this session
     */
    function registerSession(string calldata discordName)
        external
        payable
        whenNotPaused
        returns (uint64 id)
    {
        // Fee check
        if (msg.value < ENTRY_FEE)
            revert InsufficientFee(msg.value, ENTRY_FEE);

        // Name validation
        uint256 nameLen = bytes(discordName).length;
        if (nameLen == 0 || nameLen > MAX_NAME_LEN)
            revert InvalidName();

        // One active session per wallet
        if (activeSession[msg.sender] != 0)
            revert AlreadyHasActiveSession(activeSession[msg.sender]);

        // Assign IDs
        unchecked { ++sessionCounter; }
        id = sessionCounter;
        uint64 playerNum = uint64(_playerIds[msg.sender].length) + 1;

        // Write session to storage
        sessions[id] = Session({
            globalId:          id,
            playerSessionNum:  playerNum,
            player:            msg.sender,
            discordName:       discordName,
            registeredAt:      block.timestamp,
            startBlock:        block.number,
            submittedAt:       0,
            score:             0,
            questionsAnswered: 0,
            bestStreak:        0,
            tierReached:       Tier.WarmUp,
            multiplierX10:     10,   // 1.0× default
            status:            Status.Active
        });

        _playerIds[msg.sender].push(id);
        activeSession[msg.sender] = id;

        // Update player stats
        PlayerStats storage ps = playerStats[msg.sender];
        ps.totalSessions++;
        ps.totalFeesPaid += ENTRY_FEE;
        ps.lastSeen       = block.timestamp;
        if (ps.firstSeen == 0) ps.firstSeen = block.timestamp;

        // Update global stats
        globals.totalSessions++;
        globals.feesCollected += ENTRY_FEE;
        globals.lastActivity   = block.timestamp;

        // Refund any excess
        uint256 excess = msg.value - ENTRY_FEE;
        if (excess > 0) {
            (bool ok,) = msg.sender.call{value: excess}("");
            if (!ok) revert TransferFailed();
        }

        emit SessionRegistered(msg.sender, id, discordName, ENTRY_FEE, block.timestamp);
    }

    // ═══════════════════════════════════════════════
    //  SUBMIT SCORE
    // ═══════════════════════════════════════════════

    /**
     * @notice Submit the final score for the caller's active session.
     *         Called when the player stops voluntarily or answers incorrectly.
     *         Permanently records the result and clears the active session slot.
     *
     * @param score      Total points accumulated during the session
     * @param questions  Number of questions answered correctly
     * @param streak     Best consecutive correct answer streak
     * @param tier       Highest difficulty tier reached (Tier enum 0–9)
     * @param multX10    Peak score multiplier ×10 (valid range: 10–50)
     */
    function submitScore(
        uint256 score,
        uint32  questions,
        uint32  streak,
        Tier    tier,
        uint8   multX10
    ) external whenNotPaused {
        // Must have an active session
        uint64 id = activeSession[msg.sender];
        if (id == 0) revert NoActiveSession();

        Session storage s = sessions[id];
        if (s.status != Status.Active) revert SessionAlreadyFinished(id);

        // Input validation
        if (questions > 100_000)
            revert InvalidQuestions();
        if (streak > questions)
            revert InvalidQuestions();
        if (multX10 < 10 || multX10 > MAX_MULT_X10)
            revert InvalidScore();
        // Tier must be consistent with question count
        // e.g. reaching Tier.Moderate (index 2) requires at least 2 × TIER_SIZE = 10 questions
        if (questions < uint256(tier) * TIER_SIZE)
            revert InvalidScore();

        // Write result
        s.score             = score;
        s.questionsAnswered = questions;
        s.bestStreak        = streak;
        s.tierReached       = tier;
        s.multiplierX10     = multX10;
        s.submittedAt       = block.timestamp;
        s.status            = Status.Completed;

        // Clear active session slot
        activeSession[msg.sender] = 0;

        // Update player lifetime stats
        PlayerStats storage ps = playerStats[msg.sender];
        ps.completedSessions++;
        ps.totalScore        += score;
        ps.allTimeQuestions  += questions;
        ps.lastSeen           = block.timestamp;
        if (score   > ps.highScore)      ps.highScore      = score;
        if (streak  > ps.allTimeStreak)  ps.allTimeStreak  = streak;
        if (uint8(tier) > uint8(ps.bestTier)) ps.bestTier  = tier;

        // Update global stats
        globals.completedSessions++;
        globals.totalQuestionsAnswered += questions;
        globals.lastActivity            = block.timestamp;
        if (score > globals.allTimeHighScore) {
            globals.allTimeHighScore  = score;
            globals.allTimeHighPlayer = msg.sender;
            emit NewHighScore(msg.sender, score);
        }

        emit ScoreSubmitted(
            msg.sender, id, score, questions,
            streak, tier, multX10, block.timestamp
        );
    }

    // ═══════════════════════════════════════════════
    //  ABANDON SESSION
    // ═══════════════════════════════════════════════

    /**
     * @notice Abandon the caller's active session without submitting a score.
     *         No refund is given. Frees the player to register a new session.
     */
    function abandonSession() external {
        uint64 id = activeSession[msg.sender];
        if (id == 0) revert NoActiveSession();
        sessions[id].status    = Status.Abandoned;
        activeSession[msg.sender] = 0;
        globals.lastActivity   = block.timestamp;
    }

    // ═══════════════════════════════════════════════
    //  READ FUNCTIONS
    // ═══════════════════════════════════════════════

    /**
     * @notice Get the active session for a player.
     * @param player  Wallet address to query
     * @return s      The Session struct
     * @return exists True if an active session exists
     */
    function getActiveSession(address player)
        external view
        returns (Session memory s, bool exists)
    {
        uint64 id = activeSession[player];
        if (id == 0) return (s, false);
        return (sessions[id], true);
    }

    /**
     * @notice Get a session by its global ID.
     */
    function getSession(uint64 id) external view returns (Session memory) {
        if (id == 0 || id > sessionCounter) revert SessionNotFound(id);
        return sessions[id];
    }

    /**
     * @notice Get all global session IDs for a player (oldest first).
     */
    function getPlayerSessionIds(address player)
        external view
        returns (uint64[] memory)
    {
        return _playerIds[player];
    }

    /**
     * @notice Get the most recent `count` sessions for a player, newest first.
     */
    function getRecentSessions(address player, uint256 count)
        external view
        returns (Session[] memory out)
    {
        uint64[] storage ids = _playerIds[player];
        uint256 total = ids.length;
        if (count > total) count = total;
        out = new Session[](count);
        for (uint256 i = 0; i < count; i++) {
            out[i] = sessions[ids[total - 1 - i]];
        }
    }

    /**
     * @notice Get lifetime aggregated stats for a player.
     */
    function getPlayerStats(address player)
        external view
        returns (PlayerStats memory)
    {
        return playerStats[player];
    }

    /**
     * @notice Get global game statistics.
     */
    function getGlobalStats() external view returns (GlobalStats memory) {
        return globals;
    }

    /**
     * @notice Returns true if the player currently has an open session.
     */
    function hasActiveSession(address player) external view returns (bool) {
        return activeSession[player] != 0;
    }

    /**
     * @notice Current RITUAL balance held by the contract (accumulated fees).
     */
    function contractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @notice Human-readable name for a Tier enum value.
     */
    function tierName(Tier t) external pure returns (string memory) {
        if (t == Tier.WarmUp)      return "WARM-UP";
        if (t == Tier.Easy)        return "EASY";
        if (t == Tier.Moderate)    return "MODERATE";
        if (t == Tier.Steady)      return "STEADY";
        if (t == Tier.Challenging) return "CHALLENGING";
        if (t == Tier.Tough)       return "TOUGH";
        if (t == Tier.Hard)        return "HARD";
        if (t == Tier.Intense)     return "INTENSE";
        if (t == Tier.Brutal)      return "BRUTAL";
        if (t == Tier.Extreme)     return "EXTREME";
        return "UNKNOWN";
    }

    // ═══════════════════════════════════════════════
    //  OWNER FUNCTIONS
    // ═══════════════════════════════════════════════

    /**
     * @notice Withdraw all accumulated fees to the treasury address.
     */
    function withdrawFees() external onlyOwner {
        uint256 amt = address(this).balance;
        if (amt == 0) return;
        (bool ok,) = treasury.call{value: amt}("");
        if (!ok) revert TransferFailed();
        emit FeesWithdrawn(treasury, amt);
    }

    /**
     * @notice Withdraw a specific amount to the treasury.
     */
    function withdrawPartial(uint256 amt) external onlyOwner {
        if (amt > address(this).balance) revert TransferFailed();
        (bool ok,) = treasury.call{value: amt}("");
        if (!ok) revert TransferFailed();
        emit FeesWithdrawn(treasury, amt);
    }

    /**
     * @notice Update the treasury address.
     */
    function setTreasury(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit TreasurySet(treasury, next);
        treasury = next;
    }

    /**
     * @notice Pause or unpause new registrations and score submissions.
     *         abandonSession() still works when paused.
     */
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PauseToggled(_paused);
    }

    /**
     * @notice Transfer contract ownership.
     */
    function transferOwnership(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, next);
        owner = next;
    }

    /**
     * @notice Admin safety valve: mark a stale active session as Abandoned
     *         if the player has been inactive for more than 7 days.
     *         Allows the player to register fresh without submitting.
     *
     * @param id  Global session ID to abandon
     */
    function adminAbandon(uint64 id) external onlyOwner {
        Session storage s = sessions[id];
        if (s.player == address(0))      revert SessionNotFound(id);
        if (s.status != Status.Active)   revert SessionAlreadyFinished(id);
        if (block.timestamp < s.registeredAt + 7 days) revert SessionNotStale();
        s.status = Status.Abandoned;
        activeSession[s.player] = 0;
    }

    // ═══════════════════════════════════════════════
    //  FALLBACK
    // ═══════════════════════════════════════════════

    /// @notice Accept direct RITUAL transfers (tips / donations)
    receive() external payable {}
}
