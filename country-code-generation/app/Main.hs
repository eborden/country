{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}

import Streaming (Stream,Of(..))
import Siphon (Siphon)
import Colonnade (Headed)
import Data.ByteString (ByteString)
import Data.Text (Text)
import System.IO
import Data.Text.Encoding (encodeUtf8,decodeUtf8')
import Data.Char (isAlpha,toLower)
import Data.DisjointSet (DisjointSet)
import Control.Monad.Trans.Class
import Data.Foldable (for_)
import Control.Monad
import qualified Data.Set as S
import qualified Data.DisjointSet as DS
import qualified Streaming as SM
import qualified Streaming.Prelude as SMP
import qualified Siphon as S
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Text.Lazy as LT
import qualified Data.Text.Lazy.Builder as TB
import qualified Data.Text.Lazy.Builder.Int as TBI
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Streaming as BSM

main :: IO ()
main = do
  withCountries "country/src/Country/Unexposed/Encode/English.hs" englishEncoding
  withCountries "country/src/Country/Identifier.hs" identifierModule
  withCountries "country/src/Country/Unexposed/Alias.hs" aliasModule

aliasModule :: Stream (Of Country) IO r -> Stream (Of Text) IO r
aliasModule s = do
  aliasGroups <- lift buildAliasGroups
  SMP.yield "-- This module is autogenerated. Do not edit it by hand.\n"
  SMP.yield "module Country.Unexposed.Alias\n"
  SMP.yield "  ( aliases\n"
  SMP.yield "  ) where\n\n"
  SMP.yield "import Data.Text (Text)\n"
  SMP.yield "import Data.Word (Word16)\n"
  SMP.yield "import qualified Data.Text as T\n"
  SMP.yield "\n"
  SMP.yield "aliases :: [(Word16,Text)]\n"
  SMP.yield "aliases =\n"
  r <- flip mapStreamM (tagFirst s) $ \(isFirst,country) -> do
    let name = countryName country
        allNames = DS.equivalences name aliasGroups
    if isFirst
      then SMP.yield "  [ ("
      else SMP.yield "  , ("
    yieldLazyText (TB.toLazyText (TBI.decimal (countryCode country)))
    SMP.yield ", T.pack \""
    SMP.yield (countryName country)
    SMP.yield "\")\n"
    for_ allNames $ \altName -> when (altName /= name) $ do
      SMP.yield "  , ("
      yieldLazyText (TB.toLazyText (TBI.decimal (countryCode country)))
      SMP.yield ", T.pack \""
      SMP.yield altName
      SMP.yield "\")\n"
  SMP.yield "  ]\n"
  SMP.yield "{-# NOINLINE aliases #-}\n"
  return r

buildAliasGroups :: IO (DisjointSet Text)
buildAliasGroups = do
  t <- TIO.readFile "aliases.txt"
  let countryGroups = map (filter (not . T.null)) $ (map.map) T.strip $ map T.lines $ T.splitOn "\n\n" t
  let res = foldMap (DS.singletons . S.fromList) countryGroups
  return res

identifierModule :: Monad m => Stream (Of Country) m r -> Stream (Of Text) m r
identifierModule s = do
  SMP.yield "module Country.Identifier where\n\n"
  SMP.yield "-- This module is autogenerated. Do not edit it by hand.\n\n"
  SMP.yield "import Country.Unsafe (Country(..))\n"
  SMP.yield "\n"
  flip mapStreamM s $ \country -> do
    let identifier = toIdentifier (countryName country)
    SMP.yield identifier
    SMP.yield " :: Country\n"
    SMP.yield identifier
    SMP.yield " = Country "
    yieldLazyText (TB.toLazyText (TBI.decimal (countryCode country)))
    SMP.yield "\n\n"

toIdentifier :: Text -> Text
toIdentifier t = case (T.uncons . T.filter isAlpha . T.toTitle) t of
  Nothing -> T.empty
  Just (b,bs) -> T.cons (toLower b) bs

englishEncoding :: Monad m => Stream (Of Country) m r -> Stream (Of Text) m r
englishEncoding s = do
  SMP.yield "-- This module is autogenerated. Do not edit it by hand.\n"
  SMP.yield "module Country.Unexposed.Encode.English\n"
  SMP.yield "  ( countryNameQuads\n"
  SMP.yield "  ) where\n\n"
  SMP.yield "import Data.Text (Text)\n"
  SMP.yield "import Data.Word (Word16)\n"
  SMP.yield "import qualified Data.Text as T\n"
  SMP.yield "\n"
  SMP.yield "-- first value is country code, second is english name, \n"
  SMP.yield "-- third is two char code, fourth is three char code.\n"
  SMP.yield "countryNameQuads :: [(Word16,Text,(Char,Char),(Char,Char,Char))]\n"
  SMP.yield "countryNameQuads =\n"
  r <- flip mapStreamM (tagFirst s) $ \(isFirst,country) -> do
    let (a1,a2) = countryAlpha2 country
        (b1,b2,b3) = countryAlpha3 country
    if isFirst
      then SMP.yield "  [ ("
      else SMP.yield "  , ("
    yieldLazyText (TB.toLazyText (TBI.decimal (countryCode country)))
    SMP.yield ", T.pack \""
    SMP.yield (countryName country)
    SMP.yield "\",('"
    SMP.yield (T.singleton a1)
    SMP.yield "','"
    SMP.yield (T.singleton a2)
    SMP.yield "'),('"
    SMP.yield (T.singleton b1)
    SMP.yield "','"
    SMP.yield (T.singleton b2)
    SMP.yield "','"
    SMP.yield (T.singleton b3)
    SMP.yield "')"
    SMP.yield ")\n"
  SMP.yield "  ]\n"
  SMP.yield "{-# NOINLINE countryNameQuads #-}\n"
  return r

yieldLazyText :: Monad m => LT.Text -> Stream (Of Text) m ()
yieldLazyText = mapM_ SMP.yield . LT.toChunks
    
tagFirst :: Monad m => Stream (Of a) m r -> Stream (Of (Bool,a)) m r
tagFirst = SMP.zip (SMP.yield True >> SMP.repeat False)

mapStreamM :: Monad m
  => (a -> Stream (Of b) m x)
  -> Stream (Of a) m r
  -> Stream (Of b) m r
mapStreamM f = SM.concats . SM.mapsM (\(a :> s) -> return (f a >> return s))

withCountries ::
     String -- ^ file name
  -> (forall r. Stream (Of Country) IO r -> Stream (Of Text) IO r) 
  -> IO ()
withCountries fn g = 
  withFile fn WriteMode $ \output ->
  withFile "countries.csv" ReadMode $ \input -> do
    m <- id
      $ BSM.hPut output
      $ BSM.fromChunks
      $ SMP.map encodeUtf8
      $ g
      $ S.decodeCsvUtf8 siphon 
      $ BSM.toChunks
      $ BSM.fromHandle input
    case m of
      Nothing -> return ()
      Just err -> do
        hPutStrLn stderr (S.humanizeSiphonError err)
        fail "died"

data Country = Country
  { countryName :: Text
  , countryAlpha2 :: (Char,Char)
  , countryAlpha3 :: (Char,Char,Char)
  , countryCode :: Int
  }

siphon :: Siphon Headed ByteString Country
siphon = Country
  <$> S.headed "name" decodeUtf8Maybe
  <*> S.headed "alpha-2" decodeChar2
  <*> S.headed "alpha-3" decodeChar3
  <*> S.headed "country-code" decodeInt

decodeUtf8Maybe :: ByteString -> Maybe Text
decodeUtf8Maybe = either (\_ -> Nothing) Just . decodeUtf8'

decodeChar2 :: ByteString -> Maybe (Char,Char)
decodeChar2 bs = if BC.length bs == 2
  then
    let b0 = BC.index bs 0
        b1 = BC.index bs 1
     in if isUpperAscii b0 && isUpperAscii b1
          then Just (b0,b1)
          else Nothing
  else Nothing

isUpperAscii :: Char -> Bool
isUpperAscii x = x >= 'A' && x <= 'Z'

decodeChar3 :: ByteString -> Maybe (Char,Char,Char)
decodeChar3 bs = if BC.length bs == 3
  then
    let b0 = BC.index bs 0
        b1 = BC.index bs 1
        b2 = BC.index bs 2
     in if isUpperAscii b0 && isUpperAscii b1 && isUpperAscii b2
          then Just (b0,b1,b2)
          else Nothing
  else Nothing

decodeInt :: ByteString -> Maybe Int
decodeInt b = do
  (a,bsRem) <- BC.readInt b
  if BC.null bsRem
    then Just a
    else Nothing
