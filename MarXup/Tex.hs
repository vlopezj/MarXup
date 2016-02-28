{-# LANGUAGE GeneralizedNewtypeDeriving, TypeFamilies,TypeSynonymInstances,FlexibleInstances, PackageImports #-}

module MarXup.Tex where

import MarXup
import Control.Monad.Reader
import Control.Monad.RWS
import Control.Applicative
import GHC.Exts( IsString(..) )
import Data.List (intersperse,intercalate)
import MarXup.MultiRef
import System.Directory (doesFileExist)
import Data.Char (isSpace)
import Data.Map (assocs)

data ClassFile = Plain | LNCS | SIGPlan | IEEE | EPTCS | Beamer | EasyChair
  deriving Eq


------------------------------------
-- MetaData

data Key = PreClass String | PrePackage Int String | PreTheorem String String   -- priority
  deriving (Ord,Eq)

newtheorem :: String -> String -> TeX
newtheorem ident txt = do
  sty <- askClass
  unless ((sty == LNCS || sty == Beamer) && ident `elem` ["theorem", "corollary", "lemma", "definition", "proposition"]) $ do
  Tex $ metaData (PreTheorem ident txt) ""

usepkg :: String -> Int -> [String] -> TeX
usepkg ident prio options = Tex $ metaData (PrePackage prio ident) (intercalate "," options)

documentClass :: String -> [String] -> TeX
documentClass docClass options = Tex $ metaData (PreClass docClass) (intercalate "," options)


renderKey :: Key -> String -> String
renderKey o options = case o of
  PreClass name -> "\\documentclass[" ++ options ++ "]{" ++ name ++ "}"
  PrePackage _ name -> "\\usepackage[" ++ options ++ "]{" ++ name ++ "}"
  PreTheorem ident txt  -> "\\newtheorem{" ++ ident ++ "}{" ++ txt ++ "}"

newtype Tex a = Tex {fromTex :: Multi ClassFile Key a}
  deriving (Monad, MonadFix, Applicative, Functor)




---------------------------------
-- MarXup interface
instance Textual Tex where
  textual s = case break (== '\n') s of
    -- The 1st blank line of a MarXup chunk is replaced by a
    -- space. This means that to create a paragraph after an element,
    -- one needs a double blank line.
    (l,'\n':s') | all isSpace l -> tex (' ' : process s')
    _ -> tex $ process s
   where process = concatMap escape

kern :: String -> TeX
kern x = braces $ tex $ "\\kern " ++ x

escape :: Char -> [Char]
escape '\\' = "\\ensuremath{\\backslash{}}"
escape '~' = "\\ensuremath{\\sim{}}"
escape '<' = "\\ensuremath{<}"
escape '>' = "\\ensuremath{>}"
escape c | c `elem` "#^_{}&$%" = '\\':c:[]
escape c = [c]

instance Element (Tex a) where
  type Target (Tex a) = Tex a
  element = id

tex ::  String ->TeX
tex = Tex . raw

texComment :: String -> TeX
texComment s =
  forM_ (lines s) $ \line ->
    tex $ "% " <> line <> "\n"

type TeX = Tex ()

reference :: Label -> Tex ()
reference l = tex (show l)

instance Monoid (TeX) where
  mempty = tex ""
  mappend = (>>)

instance IsString (TeX) where
  fromString = textual

texLn :: String -> TeX
texLn s = tex s >> tex "\n"

texLines :: [String] -> Tex ()
texLines = mapM_ texLn

genParen :: String -> Tex a -> Tex a
genParen [l,r] x = tex [l] *> x <* tex [r]

braces,brackets :: Tex a -> Tex a
braces = genParen "{}"
brackets = genParen "[]"

backslash :: TeX
backslash = tex ['\\']

nil :: TeX
nil = braces (tex "")

-- | Command with no argument
cmd0 :: String -> Tex ()
cmd0 c = cmdn' c [] [] >> return ()

-- | Command with one argument
cmd :: String -> Tex a -> Tex a
cmd c = cmd' c []

-- | Command with options
cmd' :: String -> [String] -> Tex b -> Tex b
cmd' cmd options arg = do
  [x] <- cmdn' cmd options [arg]
  return x

-- | Command with options and many arguments
cmdn' :: String -> [String] -> [Tex a] -> Tex [a]
cmdn' cmd options args = do
  backslash >> tex cmd
  when (not $ null options) $ brackets $ sequence_ $ map tex $ intersperse "," options
  res <- sequence $ map braces args
  when (null args) $ tex "{}" -- so that this does not get glued with the next thing.
  return res

-- | Command with tex options and several arguments
cmdm :: String -> [Tex a] -> [Tex a] -> Tex [a]
cmdm cmd options args = do
  backslash >> tex cmd
  when (not $ null options) $ sequence_ $ map brackets $ options
  res <- sequence $ map braces args
  when (null args) $ tex "{}" -- so that this does not get glued with the next thing.
  return res


-- | Command with string options and several arguments; no result
cmdn'_ :: String -> [String] -> [TeX] -> Tex ()
cmdn'_ cmd options args = cmdn' cmd options args >> return ()

-- | Command with n arguments
cmdn :: String -> [Tex a] -> Tex [a]
cmdn c args = cmdn' c [] args

-- | Command with n arguments, no result
cmdn_ :: String -> [TeX] -> Tex ()
cmdn_ theCmd args = cmdn'_ theCmd [] args

-- | Environment
env :: String -> Tex a -> Tex a
env x = env' x []

-- | Environment with options
env' :: String -> [String] -> Tex a -> Tex a
env' e opts body = env'' e (map textual opts) [] body

-- | Environment with tex options and tex arguments
env'' :: String -> [TeX] -> [TeX] -> Tex a -> Tex a
env'' e opts args body = do
  cmd "begin" $ tex e
  when (not $ null opts) $ brackets $ sequence_ $ intersperse (tex ",") opts
  mapM_ braces args
  x <- body
  cmd "end" $ tex e
  return x

------------------
-- Sorted labels

data SortedLabel =  SortedLabel String Label

label :: String -> Tex SortedLabel
label s = do
  l <- Tex newLabel
  cmd "label" (reference l)
  return $ SortedLabel s l

xref :: SortedLabel -> TeX
xref (SortedLabel _ l) = do
  cmd "ref" (reference l)
  return ()

fxref :: SortedLabel -> TeX
fxref l@(SortedLabel s _) = do
  textual s
  tex "~" -- non-breakable space here
  xref l

pageref :: SortedLabel -> TeX
pageref (SortedLabel _ l) = do
  cmd "pageref" (reference l)
  return ()
  
instance Element SortedLabel where
  type Target SortedLabel = TeX
  element x = fxref x >> return ()

-----------------
-- Generate boxes


-- whenMode :: Mode -> Tex () -> Tex ()
-- whenMode mode act = do
--   interpretMode <- Tex ask
--   when (mode interpretMode) act

inBox :: Tex a -> Tex (a, BoxSpec)
inBox x = braces $ do
  tex $ "\\savebox{\\marxupbox}{"
  a <- x
  tex $
    "}"
    ++ writeBox "wd"
    ++ writeBox "ht"
    ++ writeBox "dp"
  tex $ "\\box\\marxupbox"
  b <- Tex getBoxSpec

  return (a,b)
  where writeBox l = "\\immediate\\write\\boxesfile{\\number\\"++ l ++"\\marxupbox}"


justBox :: Tex a -> Tex BoxSpec
justBox x = do
  do
    tex "\n\\savebox{\\marxupbox}{"
    x
    tex $ 
      "}"
      ++ writeBox "wd"
      ++ writeBox "ht"
      ++ writeBox "dp"
      ++ "\n"
  b <- Tex getBoxSpec

  return b
  where writeBox l = "\\immediate\\write\\boxesfile{\\number\\"++ l ++"\\marxupbox}"

renderWithBoxes :: ClassFile -> [BoxSpec] -> Tex a -> String
renderWithBoxes classFile bs (Tex t) = (preamble ++ doc)
  where (_,(_,_,metaDatum),doc) = runRWS (fromMulti $ t) classFile (0,bs,mempty)
        preamble :: String
        preamble = unlines $ map (uncurry renderKey) $ assocs metaDatum

renderSimple :: ClassFile -> Tex a -> String
renderSimple classFile = renderWithBoxes classFile []

renderTex :: ClassFile -> String -> TeX -> IO ()
renderTex classFile fname body = do
  let boxesTxt = fname ++ ".boxes"
  boxes <- getBoxInfo . map read . lines <$> do
    e <- doesFileExist boxesTxt
    if e
      then readFile boxesTxt
      else return ""
  putStrLn $ "Found " ++ show (length boxes) ++ " boxes"
  let texSource = renderWithBoxes classFile (boxes ++ repeat nilBoxSpec) wholeDoc
      wholeDoc = do
        tex $ "\\newwrite\\boxesfile"
        tex $ "\\immediate\\openout\\boxesfile="++boxesTxt++"\n\\newsavebox{\\marxupbox}"
        body
        tex "\n\\immediate\\closeout\\boxesfile"
  writeFile (fname ++ ".tex") texSource

askClass :: Tex ClassFile
askClass = Tex ask

getBoxInfo :: [Int] -> [BoxSpec]
getBoxInfo (width:height:depth:bs) = BoxSpec (scale width) (scale height) (scale depth):getBoxInfo bs
  where scale x = fromIntegral x / 65536
getBoxInfo _ = []

