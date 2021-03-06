{-# LANGUAGE LambdaCase, QuasiQuotes, TemplateHaskell, TupleSections #-}
module ChessLogic where
import ChessUtil
import Control.Arrow
import Control.Monad
import Data.Array
import Data.List
import Data.Maybe
import Text.Printf.TH
import qualified Data.Aeson as A
import qualified Data.Aeson.TH as AT

type Location = (Int, Int)
data Move = Move { mvSource :: Location, mvDest :: Location } deriving Show
newtype ChessBoard = ChessBoard (Array Location (Maybe ChessPiece)) deriving Show
data GameState = GameState {
    gsCurrentPlayer :: ChessPieceColor,
    gsBoard :: ChessBoard
    } deriving Show

instance A.ToJSON ChessBoard where toJSON (ChessBoard board) = A.toJSON $ assocs board
instance A.FromJSON ChessBoard where parseJSON aList = fmap (ChessBoard . array ((1,1), (8, 8))) $ A.parseJSON aList

data ChessPieceType = Pawn | Rook | Knight | Bishop | Queen | King deriving (Eq, Show)
data ChessPieceColor = Black | White deriving (Eq, Show)

data ChessPiece = ChessPiece {
    cpType :: ChessPieceType,
    cpColor :: ChessPieceColor,
    cpHasMoved :: Bool
    }

instance Show ChessPiece where show (ChessPiece ty col _) = [s|ChessPiece %6? %?|] ty col

fmap concat $ mapM (AT.deriveJSON AT.defaultOptions) [
    ''ChessPieceType,
    ''ChessPieceColor,
    ''ChessPiece,
    ''GameState,
    ''Move]

defaultBoard = ChessBoard . listArray ((1, 1), (8, 8)) . concat $ transpose [
    [mk Rook White, mk Knight White, mk Bishop White, mk Queen White, mk King White, mk Bishop White, mk Knight White, mk Rook White],
    [mk Pawn White, mk   Pawn White, mk   Pawn White, mk  Pawn White, mk Pawn White, mk   Pawn White, mk   Pawn White, mk Pawn White],
    [Nothing,               Nothing,         Nothing,        Nothing,       Nothing,         Nothing,         Nothing,       Nothing],
    [Nothing,               Nothing,         Nothing,        Nothing,       Nothing,         Nothing,         Nothing,       Nothing],
    [Nothing,               Nothing,         Nothing,        Nothing,       Nothing,         Nothing,         Nothing,       Nothing],
    [Nothing,               Nothing,         Nothing,        Nothing,       Nothing,         Nothing,         Nothing,       Nothing],
    [mk Pawn Black, mk   Pawn Black, mk   Pawn Black, mk  Pawn Black, mk Pawn Black, mk   Pawn Black, mk   Pawn Black, mk Pawn Black],
    [mk Rook Black, mk Knight Black, mk Bishop Black, mk Queen Black, mk King Black, mk Bishop Black, mk Knight Black, mk Rook Black]
    ] where mk piece color = Just $ ChessPiece piece color False

defaultGameState = GameState White defaultBoard

otherColor Black = White
otherColor White = Black

arr !? i = if inRange (bounds arr) i then Just (arr!i) else Nothing
getByDelta arr (dx, dy) = unfoldr (\i@(ix, iy) -> fmap ((,(ix+dx, iy+dy)) . (i,)) (arr !? i)) . ((+dx) *** (+dy))

makeMove :: GameState -> Move -> Either String GameState
makeMove (GameState curPlayer (ChessBoard board)) = aux where
    aux (Move src _) | not (inBounds src) = Left $ [s|Source %? is out of bounds|] src
    aux (Move _ dst) | not (inBounds dst) = Left $ [s|Destination %? is out of bounds|] dst
    aux move@(Move src@(x1, y1) dst@(x2, y2)) = maybe (Left $ [s|No piece is at position %?|] src) Right (board!src) >>= \case
        ChessPiece _ col _ | col /= curPlayer -> Left $ [s|%? has %?'s piece, and it's %?'s turn|] src col curPlayer
        piece@(ChessPiece Pawn col moved) -> do
            -- TODO: arbitrary promotion, en passant
            let (#) = if col == Black then (-) else (+)
            let shouldPromote = y2 == (if col == Black then 1 else 8)
            let piece' = if shouldPromote then piece { cpType = Queen } else piece
            case () of
                _ | (dst == (x1, y1#1)) && (isNothing (board!dst)) -> uncheckedMakeMove move piece'
                _ | (dst == (x1, y1#2)) && (all isNothing $ map (board!) [(x1,y1#1), dst]) && (moved == False) -> uncheckedMakeMove move piece'
                _ | (dst `elem` [(x1-1, y1#1), (x1+1, y1#1)]) && (isJust (board!dst)) -> uncheckedMakeMove move piece'
                _ -> Left $ [s|No valid moves for Pawn at %?|] src
        piece@(ChessPiece Rook _ _) -> straightLineMovement orthogonalDeltas move piece
        piece@(ChessPiece Bishop _ _) -> straightLineMovement diagonalDeltas move piece
        piece@(ChessPiece Queen _ _) -> straightLineMovement (orthogonalDeltas ++ diagonalDeltas) move piece
        piece@(ChessPiece Knight _ _) -> moveIfInSet move piece (knightMoveSet src)
        piece@(ChessPiece King _ _) -> moveIfInSet move piece (kingMoveSet src) `onFailDo` castleMovement piece src dst
    castleMovement (ChessPiece _ c1 moved) src@(x1, y1) (x2, y2) = do
        when moved $ Left "The king must not have previously moved in order to castle."
        when (y1 /= y2) $ Left "Castling is only valid within the same row."
        when ((abs $ x2 - x1) /= 2) $ Left "Castling requires the king to move exactly 2 squares."
        let deltaX = (x2 - x1) `div` 2
        let squaresBetween = getByDelta board (deltaX, 0) src
        let rookPos = fst $ foldl (\(rookPos, done) (i, e) -> if done then (rookPos, done) else case e of {
            Just (ChessPiece Rook c2 False) | c1 == c2 -> (Just i, True);
            Nothing -> (Nothing, False); _ -> (Nothing, True)}) (Nothing, False) squaresBetween
        case rookPos of
            Nothing -> Left "There is no path from the king to a same-colored, unmoved rook."
            Just rookPos -> do
                let newKing = ((x2, y2), Just (ChessPiece King c1 True))
                let newRook = ((x1+deltaX, y1), Just (ChessPiece Rook c1 True))
                Right (GameState (otherColor curPlayer) (ChessBoard $ board // [(src, Nothing), (rookPos, Nothing), newKing, newRook]))
    knightMoveSet (x, y) = let r = [-2, -1, 1, 2] in [(x+dx, y+dy) | dx <- r, dy <- r, abs dy /= abs dx]
    kingMoveSet (x, y) = (map ((x+) *** (y+)) (orthogonalDeltas ++ diagonalDeltas))
    takeWhileUnoccupied = reverse . fst . foldl (\(a, done) (i,e) -> (if done then a else (i,e):a, done || isJust e)) ([], False)
    straightLineMovement deltas move@(Move src _) piece = moveIfInSet move piece $
        concatMap (\delta -> map fst . takeWhileUnoccupied $ getByDelta board delta src) deltas
    orthogonalDeltas = [(-1, 0), (1, 0), (0, -1), (0, 1)]
    diagonalDeltas = [(-1, -1), (-1, 1), (1, 1), (1, -1)]
    moveIfInSet move piece set = if mvDest move `elem` set then uncheckedMakeMove move piece else Left $ [s|Invalid move for %?|] (cpType piece)
    uncheckedMakeMove (Move src dst) piece = do
        when (maybe False ((== curPlayer) . cpColor) (board!dst)) $ Left "Can't take a piece of the same color"
        Right (GameState (otherColor curPlayer) (ChessBoard $ board // [(src, Nothing), (dst, Just (piece {cpHasMoved=True}))]))
    inBounds = inRange ((1,1), (8, 8))

eitherToBool = either (const False) (const True)

validMoves :: GameState -> Location -> Array Location Bool
validMoves gs@(GameState _ (ChessBoard board)) loc = array (bounds board) . map (\(i, x) -> (i, eitherToBool . abortIfInCheck $ makeMove gs (Move loc i))) $ assocs board

anyValidMovesExist :: GameState -> Bool
anyValidMovesExist gs@(GameState player (ChessBoard board)) = any (\i -> any id (elems $ validMoves gs i)) (indices board)

abortIfInCheck :: Either String GameState -> Either String GameState
abortIfInCheck (Right gs@(GameState player _)) | inCheck gs (otherColor player) = Left "Can't move into check"
abortIfInCheck x = x

inCheck :: GameState -> ChessPieceColor -> Bool
inCheck (GameState _ cb@(ChessBoard board)) player = any canTakeKing (indices board) where
    canTakeKing src = eitherToBool $ makeMove (GameState (otherColor player) cb) (Move src dst)
    dst = fst . head . filter (\(i, Just x) -> cpType x == King && cpColor x == player) $ filter (isJust . snd) (assocs board)
