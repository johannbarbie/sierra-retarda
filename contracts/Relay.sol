// SPDX-License-Identifier: MPL
pragma solidity >=0.4.22 <0.8.0;
import {BytesLib} from '@interlay/bitcoin-spv-sol/contracts/BytesLib.sol';
import {BTCUtils} from '@interlay/bitcoin-spv-sol/contracts/BTCUtils.sol';
import {IRelay} from './IRelay.sol';

contract Relay is IRelay {
  using BytesLib for bytes;
  using BTCUtils for bytes;

  // CONSTANTS
  uint256 public constant DIFFICULTY_ADJUSTMENT_INTERVAL = 2016;
  uint8 internal constant BUFFER_CAPACITY = 255;

  // EXCEPTION MESSAGES
  // OPTIMIZATION: limit string length to 32 bytes
  string internal constant ERR_INVALID_HEADER_SIZE = 'Invalid block header size';
  string internal constant ERR_PREVIOUS_BLOCK = 'Previous block hash not found';
  string internal constant ERR_LOW_DIFFICULTY = 'Insufficient difficulty';
  string internal constant ERR_DIFF_PERIOD = 'Invalid difficulty period';
  string internal constant ERR_DIFF_TARGET_HEADER = 'Incorrect difficulty target';
  string internal constant ERR_INVALID_HEADER_BATCH = 'Invalid block header batch';

  uint256 public pointers;

  // target of the difficulty period
  uint256 public _epochStartTarget;
  uint256 public _epochEndTarget;

  uint64 public _epochStartTime;
  uint64 public _epochEndTime;

  uint256[] public pendingData;
  bytes32[] public pendingHashes;
  
  constructor(bytes32 header, uint256 height) public {
    for(uint256 i = 0; i < BUFFER_CAPACITY; i++) {
      pendingData.push(0);
      pendingHashes.push(0x0);
    }
    uint8[] memory empty = new uint8[](0);
    pointers = _packState(0, 0, empty);
  }

  function _packData(uint32 prevPos, uint32 blockHeight) internal pure returns (uint256 data) {
    data = uint256(prevPos) << 32 | uint256(blockHeight);
  }

  function _unpackData(uint256 data) internal pure returns (uint32 height, uint32 prevPos) {
    height = uint32(data);
    prevPos = uint32(data >> 32);
  }

  function _packState(uint8 freePos, uint8 tailPos, uint8[] memory tips) internal pure returns (uint256) {
    return (uint256(freePos) | uint256(tailPos << 8));
  }

  function _unpackState(uint256 pointers) internal pure returns (uint8 freePos, uint8 tailPos, uint8[] memory tips) {
    uint8[] memory empty = new uint8[](0);
    return (uint8(pointers), uint8(pointers >> 8), empty);
  }

  /**
   * @notice Checks if the difficulty target should be adjusted at this block height
   * @param height Block height to be checked
   * @return True if block height is at difficulty adjustment interval, otherwise false
   */
  function _isPeriodStart(uint32 height) internal pure returns (bool) {
    return height % DIFFICULTY_ADJUSTMENT_INTERVAL == 0;
  }

  function _isPeriodEnd(uint32 height) internal pure returns (bool) {
    return height % DIFFICULTY_ADJUSTMENT_INTERVAL == 2015;
  }

  function _getFreeCapacity(uint256 points) internal pure returns (uint8 capacity, uint8 freePos) {
    uint8 endPos;
    (freePos, endPos,) = _unpackState(points);
    if (endPos == freePos) {
      capacity = BUFFER_CAPACITY;
    }
    if (freePos > endPos) {
      capacity =  BUFFER_CAPACITY - (freePos - endPos);
    }
    // (endPos > freePos)
    capacity = endPos - freePos;
  }

  function _getBest(uint256 points) internal view returns (bytes32 hash, uint32 height) {
    // load all tips
    // for each tip, get height
    // return highers
    uint8[] memory tips;
    (,,tips) = _unpackState(points);
    height = 0;
    uint256 bestTip = 0;
    // we skip position 0 (free pointer) and 1 (end pointer here)
    for (uint256 i = 2; i < tips.length; i++) {
      // stop if no more tips in list
      if (tips[i] == 0xff) {
        break;
      }
      // set height if larger than what we had before
      uint32 tipHeight = uint32(pendingData[tips[i]]);
      if (tipHeight > height) {
        height = tipHeight;
        bestTip = i;
      }
    }
    hash = pendingHashes[bestTip];
  }

  /**
   * @dev Core logic for block header validation
   */
  function _submitBlockHeader(uint8 prevPos, bytes memory header) internal returns (uint8) {
    require(header.length == 80, ERR_INVALID_HEADER_SIZE);

    bytes32 hashCurrBlock = header.hash256();

    // TODO: Fail if block already exists
    uint256 points = pointers;
    // how to check inclusion?
    // if prev is not tip, then this is a fork
    // A: walk from all tips to prev, try to find duplicate
    // B: ignore, duplicates are not really a problem
    // require(_headers[hashCurrBlock].height == 0, ERR_DUPLICATE_BLOCK);

    // Fail if previous block hash not in current state of main chain
    bytes32 hashPrevBlock = header.extractPrevBlockLE().toBytes32();
    require(pendingHashes[prevPos] == hashPrevBlock, ERR_PREVIOUS_BLOCK);

    uint256 target = header.extractTarget();

    // Check the PoW solution matches the target specified in the block header
    require(
      abi.encodePacked(hashCurrBlock).reverseEndianness().bytesToUint() <=
        target,
      ERR_LOW_DIFFICULTY
    );

    uint32 prevHeight;
    (prevHeight,) = _unpackData(pendingData[prevPos]);
    uint32 height = 1 + prevHeight;

    // Check the specified difficulty target is correct
    if (_isPeriodStart(height)) {
      require(
          isCorrectDifficultyTarget(
              _epochStartTarget,
              _epochStartTime,
              _epochEndTarget,
              _epochEndTime,
              target
          ),
          ERR_DIFF_TARGET_HEADER
      );

      _epochStartTarget = target;
      _epochStartTime = header.extractTimestamp();

      delete _epochEndTarget;
      delete _epochEndTime;
    } else if (_isPeriodEnd(height)) {
      // only update if end to save gas
      _epochEndTarget = target;
      _epochEndTime = header.extractTimestamp();
    }


    uint8 freePos;
    (,freePos) = _getFreeCapacity(pointers);
    // todo: check that enough space left, if not, flush buffer

    pendingData[freePos] = _packData(prevPos, height);
    pendingHashes[freePos] = hashCurrBlock;

    // update tips
    // move free pointer
    return freePos;
  }

  /**
   * @notice Validates difficulty interval
   * @dev Reverts if previous period invalid
   * @param prevStartTarget Period starting target
   * @param prevStartTime Period starting timestamp
   * @param prevEndTarget Period ending target
   * @param prevEndTime Period ending timestamp
   * @param nextTarget Next period starting target
   * @return True if difficulty level is valid
   */
  function isCorrectDifficultyTarget(
    uint256 prevStartTarget,
    uint64 prevStartTime,
    uint256 prevEndTarget,
    uint64 prevEndTime,
    uint256 nextTarget
  ) public pure returns (bool) {
    require(
      BTCUtils.calculateDifficulty(prevStartTarget) ==
          BTCUtils.calculateDifficulty(prevEndTarget),
      ERR_DIFF_PERIOD
    );

    uint256 expectedTarget = BTCUtils.retargetAlgorithm(
      prevStartTarget,
      prevStartTime,
      prevEndTime
    );

    return (nextTarget & expectedTarget) == nextTarget;
  }

  /**
   * @dev See {IRelay-submitBlockHeader}.
   */
  function submitBlockHeader(uint8 prevPos, bytes calldata header) external override {
    _submitBlockHeader(prevPos, header);
  }

  /**
   * @dev See {IRelay-submitBlockHeaderBatch}.
   */
  function submitBlockHeaderBatch(uint8 prevPos, bytes calldata headers) external override {
    require(headers.length % 80 == 0, ERR_INVALID_HEADER_BATCH);

    for (uint256 i = 0; i < headers.length / 80; i = i + 1) {
      bytes memory header = headers.slice(i * 80, 80);
      prevPos = _submitBlockHeader(prevPos, header);
    }
  }

  /**
   * @dev See {IRelay-getBlockHeight}.
   */
  function getBlockHeight(bytes32 digest)
    external
    override
    view
    returns (uint32)
  {
    //return _headers[digest].height;
  }

  /**
   * @dev See {IRelay-getBlockHash}.
   */
  function getBlockHash(uint32 height)
      external
      override
      view
      returns (bytes32)
  {
      // bytes32 digest = _chain[height];
      // require(digest > 0, ERR_BLOCK_NOT_FOUND);
      // return digest;
  }

  /**
   * @dev See {IRelay-getBestBlock}.
   */
  function getBestBlock()
      external
      override
      view
      returns (bytes32 digest, uint32 height)
  {
      return _getBest(pointers);
  }
}
