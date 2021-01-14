module TT where

import Graph
import Data.List
import Control.Monad.Except
import Control.Monad.RWS
import Data.Char

type Name = String

data Constraint
    = UniverseID :>: UniverseID
    | UniverseID :>=: UniverseID

appConstraints :: OrderingGraph -> [Constraint] -> Res OrderingGraph
appConstraints g (i :>: j:cs) = do
    let g' = insertEdge j i True g
    unless (acyclic i g') (throwError ("Could not add universe constraint " ++ show i ++ " > " ++ show j ++ "."))
    appConstraints g' cs
appConstraints g (i :>=: j:cs) = do
    let g' = insertEdge j i False g
    unless (acyclic i g') (throwError ("Could not add universe constraint " ++ show i ++ " ≥ " ++ show j ++ "."))
    appConstraints g' cs
appConstraints g [] = pure g

data Var
    = Dummy
    | User String
    deriving(Eq)

instance Show Var where
    show (User s) = s
    show Dummy = "_"

data Exp
    = Ann Exp Exp
    | Set UniverseID
    | Hole
    | Pi Var (Abstraction Exp)
    -- variable is marked with a type if free
    | Var Int (Maybe Val)
    | Free Name
    | App Exp Exp
    | Lam Var (Abstraction Exp)
    deriving(Show)

showExp :: [Var] -> Exp -> String
showExp ns (Ann e t) = parens (showExp ns e) ++ " : " ++ showExp ns t
showExp ns (Set i) = "Type." ++ show i
showExp ns Hole = "_"
showExp ns (Pi Dummy (Abs (Just d) r)) = parens (showExp ns d) ++ " -> " ++ showExp (Dummy:ns) r
showExp ns (Pi n (Abs (Just d) r)) = "forall (" ++ show n ++ ": " ++ showExp ns d ++ "), " ++ showExp (n:ns) r
showExp ns (Var i _) | i >= length ns = show i
showExp ns (Var i _) = show (ns !! i)
showExp ns (Free n) = n
showExp ns (App f x) = parens (showExp ns f) ++ " " ++ parens (showExp ns x)
showExp ns (Lam n (Abs Nothing r)) = "fun " ++ show n ++ " => " ++ showExp (n:ns) r
showExp ns (Lam n (Abs (Just d) r)) = "fun (" ++ show n ++ ": " ++ showExp ns d ++ ") => " ++ showExp (n:ns) r

data Abstraction e
    = Abs (Maybe e) e
    deriving(Eq,Show)

data ValVar
    = VVar Int
    | VFree Name
    deriving(Eq)

data Val
    = VApp ValVar [Val]
    | VSet UniverseID
    | VLam (Abstraction Val)
    | VPi (Abstraction Val)
    deriving(Eq)

varUsed :: Int -> Val -> Bool
varUsed n (VApp (VVar n') vs) = n == n' || any (varUsed n) vs
varUsed n (VApp _ vs) = any (varUsed n) vs
varUsed n (VLam abs) = varUsedAbs n abs
varUsed n (VPi abs) = varUsedAbs n abs
varUsed _ _ = False

varUsedAbs :: Int -> Abstraction Val -> Bool
varUsedAbs n (Abs (Just d) r) = varUsed n d || varUsed (n+1) r
varUsedAbs n (Abs Nothing r) = varUsed (n+1) r

boundVarUsed :: Abstraction Val -> Bool
boundVarUsed (Abs _ r) = varUsed 0 r

names :: [String]
names = [1..] >>= flip replicateM ['a'..'z']

showNamesAbs :: [String] -> [Var] -> Abstraction Val -> (String,Maybe String,String)
showNamesAbs (u:unused) ns (Abs d r) = (u,fmap (showNames unused ns) d,showNames unused (User u:ns) r)

parens :: String -> String
parens s | any isSpace s = "(" ++ s ++ ")"
parens s = s

showNames :: [Name] -> [Var] -> Val -> String
showNames us ns (VLam abs) =
    let (v,t,x) = showNamesAbs us ns abs
    in case t of
        Just t -> "fun (" ++ v ++ " : " ++ t ++ ") => " ++ x
        _ -> "lam " ++ v ++ " => " ++ x
showNames us ns (VPi abs) =
    let (v,Just t,x) = showNamesAbs us ns abs
    in  if boundVarUsed abs then
            "forall (" ++ v ++ " : " ++ t ++ "), " ++ x
        else parens t ++ " -> " ++ x
showNames us ns (VApp (VVar i) vs) = (if length ns <= i then show i else show (ns !! i)) ++ concatMap ((' ':) . parens . showNames us ns) vs
showNames us ns (VApp (VFree i) vs) = i ++ concatMap ((' ':) . parens . showNames us ns) vs
showNames us ns (VSet i) = "Type." ++ show i

showVal :: [Var] -> Val -> String
showVal = showNames names

instance Show Val where
    show = showNames names []

data CtxElem
    = CtxAxiom Name Val
    | CtxDelta Name Val Val
    | CtxRedex Val Val

ctxNames :: Ctx -> [Name]
ctxNames = concatMap (\x -> case x of
    CtxAxiom n _ -> [n]
    CtxDelta n _ _ -> [n]
    CtxRedex _ _ -> [])

getElem :: Name -> Ctx -> Maybe CtxElem
getElem n (a@(CtxAxiom m _):_) | n == m = Just a
getElem n (a@(CtxDelta m _ _):_) | n == m = Just a
getElem n (_:xs) = getElem n xs
getElem _ [] = Nothing

instance Show CtxElem where
    show (CtxAxiom n t) = "Axiom '" ++ n ++ "' : " ++ show t ++ "."
    show (CtxDelta n t d) = "Definition '" ++ n ++ "' : " ++ show t ++ "\n    := " ++ show d ++ "."
    show (CtxRedex u v) = "Reduction (" ++ show u ++ ")\n    := " ++ show v ++ "."

    showList xs s = intercalate "\n\n" (fmap show xs) ++ s

type Ctx = [CtxElem]

typeInCtx :: Name -> Ctx -> Maybe Val
typeInCtx n (CtxAxiom m t:_) | n == m = Just t
typeInCtx n (CtxDelta m t _:_) | n == m = Just t
typeInCtx n (_:xs) = typeInCtx n xs
typeInCtx _ [] = Nothing

deltaInCtx :: Name -> Ctx -> Maybe Val
deltaInCtx n (CtxDelta m _ r:_) | n == m = Just r
deltaInCtx n (_:xs) = deltaInCtx n xs
deltaInCtx _ [] = Nothing

trace :: String -> Res a -> Res a
trace s r = catchError r (\e -> throwError (e ++ "\n" ++ s))

-- evaluation environments - should NOT include references to itself!
type Env = [Maybe Val]
type Res = RWST [Var] [Constraint] UniverseID (Except String)

runRes :: UniverseID -> Res a -> Either String (a,UniverseID)
runRes u r = fmap (\(a,b,_) -> (a,b)) (runExcept (runRWST r [] u))

withVar :: Var -> Res a -> Res a
withVar n = local (n:)

getVars :: Res [Var]
getVars = ask

freshUniverse :: Res UniverseID
freshUniverse = do
    u <- get
    put (u+1)
    pure u

constrain :: Constraint -> Res ()
constrain c = tell [c]

modifEnv :: (Int -> Int) -> Env -> Env
modifEnv f = fmap (fmap (modifFree f 0))

modifAbs :: (Int -> Int) -> Int -> Abstraction Val -> Abstraction Val
modifAbs f n (Abs d r) = Abs (fmap (modifFree f n) d) (modifFree f (n+1) r)

modifFree :: (Int -> Int) -> Int -> Val -> Val
modifFree f n (VApp (VVar i) vs) | i >= n = VApp (VVar (f i)) (fmap (modifFree f n) vs)
modifFree f n (VApp v vs) = VApp v (fmap (modifFree f n) vs)
modifFree f n (VLam abs) = VLam (modifAbs f n abs)
modifFree f n (VPi abs) = VPi (modifAbs f n abs)
modifFree _ _ (VSet i) = VSet i

substValAbs :: Ctx -> Int -> Val -> Abstraction Val -> Res (Abstraction Val)
substValAbs g n x (Abs d r) = do
    d' <- mapM (substVal g n x) d
    r' <- substVal g (n+1) (modifFree (+1) 0 x) r
    pure (Abs d' r')

-- beta-reduction
substVal :: Ctx -> Int -> Val -> Val -> Res Val
substVal g n x e@(VApp (VVar i) xs) | i == n = do
    xs' <- mapM (substVal g n x) xs
    foldM (evalApp g) x xs'
substVal g n x (VApp i xs) = VApp i <$> mapM (substVal g n x) xs
substVal g n x (VLam abs) = VLam <$> substValAbs g n x abs
substVal g n x (VPi abs) = VPi <$> substValAbs g n x abs
substVal g n x (VSet i) = pure (VSet i)

evalAbs :: Ctx -> Abstraction Exp -> Res (Abstraction Val)
evalAbs g (Abs d r) = do
    d' <- mapM (eval g) d
    r' <- eval g r
    pure (Abs d' r')

eval :: Ctx -> Exp -> Res Val
eval g (Var i _) = pure (VApp (VVar i) [])
eval g (Free n) = pure (VApp (VFree n) [])
eval g (Ann x t) = eval g x
eval g (Set i) = pure (VSet i)
eval g (Pi n abs) = VPi <$> evalAbs g abs
eval g (App f x) = do
    f' <- eval g f
    x' <- eval g x
    evalApp g f' x'
eval g (Lam n abs) = VLam <$> evalAbs g abs

evalApp :: Ctx -> Val -> Val -> Res Val
evalApp g (VApp n vs) v = pure (VApp n (vs ++ [v]))
evalApp g f@(VLam (Abs _ x)) v = fmap (modifFree (\x->x-1) 0) (substVal g 0 (modifFree (+1) 0 v) x)
evalApp g f@(VPi (Abs _ x)) v = fmap (modifFree (\x->x-1) 0) (substVal g 0 (modifFree (+1) 0 v) x)
evalApp _ f x = error ("CRITICAL ERROR (this should not occur): non-function application of " ++ show f ++ " to " ++ show x)

ehnf :: Ctx -> Val -> Res Val
ehnf g v@(VApp (VFree n) xs) = case deltaInCtx n g of
    Just d -> foldM (evalApp g) d xs >>= ehnf g
    _ -> pure v
ehnf _ v = pure v

-- match val, redex
matchRedex :: Ctx -> Val -> Val -> Res Bool
matchRedex g (VSet _) (VSet _) = pure True
matchRedex g (VPi (Abs _ a)) (VPi (Abs _ b)) = matchRedex g a b
matchRedex g (VLam (Abs _ a)) (VLam (Abs _ b)) = matchRedex g a b
matchRedex g (VApp n as) (VApp m bs) | n == m && length as == length bs = and <$> zipWithM (matchRedex g) as bs
matchRedex g a b = do
    a' <- reduce g a
    b' <- reduce g b
    case (a',b') of
        (Just a,Just b) -> matchRedex g a b
        (Just a,Nothing) -> matchRedex g a b
        (Nothing,Just b) -> matchRedex g a b
        (Nothing,Nothing) -> pure False

rhoReduce :: Ctx -> Val -> Ctx -> Res (Maybe Val)
rhoReduce g (VApp n ns) (CtxRedex (VApp m ms) o:xs) | n == m && length ns >= length ms = do
    match <- and <$> zipWithM (matchRedex g) (take (length ms) ns) ms
    if match then
        Just <$> foldM (evalApp xs) o (drop (length ms) ns)
    else
        rhoReduce g (VApp n ns) xs
rhoReduce g v (_:xs) = rhoReduce g v xs
rhoReduce _ _ _ = pure Nothing

deltaReduce :: Ctx -> Val -> Res (Maybe Val)
deltaReduce g (VApp (VFree n) ns) = mapM (\x -> foldM (evalApp g) x ns) (deltaInCtx n g)
deltaReduce _ _ = pure Nothing

reduce :: Ctx -> Val -> Res (Maybe Val)
reduce g v = do
    r <- rhoReduce g v g
    case r of
        Nothing -> deltaReduce g v
        Just r -> pure (Just r)

fit :: Ctx -> Val -> Val -> Res ()
fit g v0@(VPi ab) v1@(VPi bb) = fitAbs g ab bb
fit g v0@(VLam ab) v1@(VLam bb) = fitAbs g ab bb
fit g (VSet i) (VSet j) = tell [j :>=: i]
fit g v0@(VApp a as) v1@(VApp b bs) | length as == length bs && a == b =
    mapM_ (uncurry (fit g)) (zip as bs)
fit g a b = do
    a' <- reduce g a
    b' <- reduce g b
    case (a', b') of
        (Just a,Just b) -> fit g a b
        (Just a,Nothing) -> fit g a b
        (Nothing,Just b) -> fit g a b
        (Nothing,Nothing) -> do
            vs <- getVars
            throwError ("Could not fit type \"" ++ showVal vs a ++ "\" to \"" ++ showVal vs b ++ "\".")

fitAbs :: Ctx -> Abstraction Val -> Abstraction Val -> Res ()
fitAbs g (Abs (Just a) b) (Abs (Just x) y) = fit g a x >> fit g b y
fitAbs g (Abs _ a) (Abs _ b) = fit g a b

markFree :: Int -> Val -> Exp -> Exp
markFree n x (Var i _) | n == i = Var i (Just x)
markFree n x (Lam u abs) = Lam u (markFreeAbs n x abs)
markFree n x (Pi u abs) = Pi u (markFreeAbs n x abs)
markFree n x (App f a) = App (markFree n x f) (markFree n x a)
markFree n x (Ann e t) = Ann (markFree n x e) (markFree n x t)
markFree _ _ (Set i) = Set i
markFree _ _ (Free n) = Free n
markFree _ _ (Var i t) = Var i t
markFree _ _ Hole = Hole

markFreeAbs :: Int -> Val -> Abstraction Exp -> Abstraction Exp
markFreeAbs n x (Abs d r) = Abs (fmap (markFree n x) d) (markFree (n+1) (modifFree (+1) 0 x) r)

infer :: Ctx -> Exp -> Res Val
infer g (Set i) = do
    j <- freshUniverse
    tell [j :>: i]
    pure (VSet j)
infer g (Var i (Just t)) = pure t
infer g (Free n) = case typeInCtx n g of
    Just t -> pure t
    Nothing -> throwError ("Undefined identifier \"" ++ show n ++ "\"")
infer g (Ann x t) = do
    i <- freshUniverse
    check g t (VSet i)
    t' <- eval g t
    check g x t'
    pure t'
infer g (Lam n (Abs (Just t) x)) = do
    i <- freshUniverse
    check g t (VSet i)
    dt <- eval g t
    rt <- withVar n $ infer g (markFree 0 (modifFree (+1) 0 dt) x)
    pure (VPi (Abs (Just dt) rt))
infer g (Pi n (Abs (Just d) r)) = do
    i <- freshUniverse
    j <- freshUniverse
    k <- freshUniverse
    check g d (VSet i)
    dt <- eval g d
    withVar n $ check g (markFree 0 (modifFree (+1) 0 dt) r) (VSet j)
    tell [k :>=: i, k :>=: j]
    pure (VSet k)
infer g (App f x) = do
    s <- infer g f >>= ehnf g
    case s of
        VPi (Abs (Just d) _) -> do
            check g x d
            x' <- eval g x
            evalApp g s x'
        _ -> do
            vs <- getVars
            throwError ("Non-function application of \"" ++ showVal vs s ++ "\" to \"" ++ showExp vs x ++ "\".")
infer _ x = do
    vs <- getVars
    throwError ("Could not infer type of \"" ++ showExp vs x ++ "\".")

check :: Ctx -> Exp -> Val -> Res ()
check g (Lam n (Abs t x)) (VPi (Abs (Just d) r)) = do
    case t of
        Just t -> do
            i <- freshUniverse
            check g t (VSet i)
            t <- eval g t
            fit g t d
        _ -> pure ()
    withVar n $ check g (markFree 0 (modifFree (+1) 0 d) x) r
check g Hole t = do
    vs <- getVars
    throwError ("Found hole of type \"" ++ showVal vs t ++ "\".")
check g x t = do
    xt <- infer g x
    fit g xt t

inferWithOrderCheck :: Ctx -> OrderingGraph -> Exp -> Res (Val,OrderingGraph)
inferWithOrderCheck g gr e = do
    (v,c) <- listen (infer g e)
    gr <- appConstraints gr c
    pure (v,gr)

checkWithOrderCheck :: Ctx -> OrderingGraph -> Exp -> Val -> Res OrderingGraph
checkWithOrderCheck g gr e t = do
    (_,c) <- listen (check g e t)
    appConstraints gr c

showPar :: Show x => x -> String
showPar x | ' ' `elem` show x = "(" ++ show x ++ ")"
showPar x = show x