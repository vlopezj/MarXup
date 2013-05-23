{-# LANGUAGE GeneralizedNewtypeDeriving, TypeFamilies #-}

module MarXup.Tex where

import MarXup
import Control.Monad.Reader
import Control.Applicative
import GHC.Exts( IsString(..) )
import System.FilePath
import System.Environment
import Data.List (intersperse)
import MarXup.MultiRef
import Data.Monoid


newtype Tex a = Tex (ReaderT FilePath Multi a)
  deriving (Monad, MonadFix, Applicative, Functor, MonadReader FilePath)

---------------------------------
-- MarXup interface
textual :: String -> TeX
textual s = Tex $ lift (Raw $ concatMap escape s) 

escape '\\' = "\\ensuremath{\\backslash{}}"            
escape '~' = "\\ensuremath{\\sim{}}"            
escape c | c `elem` "{}&$" = '\\':c:[]
escape c = [c]

text = textual 

instance Element (Tex a) where
  type Target (Tex a) = Tex a
  element = id

tex :: String -> TeX
tex = Tex . lift . Raw
type TeX = Tex ()

newLabel :: Tex Label
newLabel = Tex $ lift Label  
reference = Tex . lift . Refer

instance Monoid (TeX) where  
  mempty = text ""
  mappend = (>>)
  
instance IsString (TeX) where  
  fromString = text
  
renderToDisk :: Tex a -> IO ()                   
renderToDisk (Tex t) = do
  fname <- getProgName
  writeToDisk (Target (fname <.> "tex") $ runReaderT t fname)
                    
render :: Tex a -> [String]    
render (Tex t) = renderMainTarget (runReaderT t "<interactive>")
    
texLn :: String -> TeX
texLn s = tex s >> tex "\n"

texLines :: [String] -> Tex ()
texLines = mapM_ texLn

genParen :: String -> Tex a -> Tex a
genParen [l,r] x = tex [l] *> x <* tex [r]

braces :: Tex a -> Tex a
braces = genParen "{}"
brackets = genParen "[]"

backslash = tex ['\\']

nil :: TeX
nil = braces (tex "")

cmd0 c = cmdn' c [] [] >> return ()

cmd c = cmd' c []

cmd' cmd options arg = do
  [x] <- cmdn' cmd options [arg]
  return x

cmdn' :: String -> [String] -> [Tex a] -> Tex [a]
cmdn' cmd options args = do 
  backslash >> tex cmd
  when (not $ null options) $ brackets $ sequence_ $ map tex $ intersperse "," options
  res <- sequence $ map braces args
  when (null args) $ tex "{}" -- so that this does not get glued with the next thing.
  return res

cmdm :: String -> [Tex a] -> [Tex a] -> Tex [a]
cmdm cmd options args = do 
  backslash >> tex cmd
  when (not $ null options) $ sequence_ $ map brackets $ options
  res <- sequence $ map braces args
  when (null args) $ tex "{}" -- so that this does not get glued with the next thing.
  return res


cmdn'_ :: String -> [String] -> [Tex a] -> Tex ()
cmdn'_ cmd options args = cmdn' cmd options args >> return ()

cmdn cmd args = cmdn' cmd [] args
cmdn_ cmd args = cmdn'_ cmd [] args

-- | Environment
env :: String -> Tex a -> Tex a
env x = env' x []

-- | Environment with options
env' :: String -> [String] -> Tex a -> Tex a
env' e opts body = do
  cmd "begin" $ tex e
  when (not $ null opts) $ brackets $ sequence_ $ map tex $ intersperse "," opts
  x <- body
  cmd "end" $ tex e
  return x


label = do
  l <- newLabel
  cmd "label" (reference l)
  
xref l = do
  cmd "ref" (reference l)
