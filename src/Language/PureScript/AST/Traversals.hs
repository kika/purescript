{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- AST traversal helpers
--
module Language.PureScript.AST.Traversals where

import Prelude ()
import Prelude.Compat

import Data.Maybe (mapMaybe)
import Data.List (mapAccumL)
import Data.Foldable (fold)
import qualified Data.Set as S

import Control.Monad
import Control.Arrow ((***), (+++))

import Language.PureScript.AST.Binders
import Language.PureScript.AST.Literals
import Language.PureScript.AST.Declarations
import Language.PureScript.Types
import Language.PureScript.Traversals
import Language.PureScript.Names

everywhereOnValues
  :: (Declaration -> Declaration)
  -> (Expr -> Expr)
  -> (Binder -> Binder)
  -> ( Declaration -> Declaration
     , Expr -> Expr
     , Binder -> Binder
     )
everywhereOnValues f g h = (f', g', h')
  where
  f' :: Declaration -> Declaration
  f' (DataBindingGroupDeclaration ds) = f (DataBindingGroupDeclaration (map f' ds))
  f' (ValueDeclaration name nameKind bs val) = f (ValueDeclaration name nameKind (map h' bs) ((map (g' *** g') +++ g') val))
  f' (BindingGroupDeclaration ds) = f (BindingGroupDeclaration (map (\(name, nameKind, val) -> (name, nameKind, g' val)) ds))
  f' (TypeClassDeclaration name args implies ds) = f (TypeClassDeclaration name args implies (map f' ds))
  f' (TypeInstanceDeclaration name cs className args ds) = f (TypeInstanceDeclaration name cs className args (mapTypeInstanceBody (map f') ds))
  f' (PositionedDeclaration pos com d) = f (PositionedDeclaration pos com (f' d))
  f' other = f other

  g' :: Expr -> Expr
  g' (Literal l) = g (Literal (lit g' l))
  g' (UnaryMinus v) = g (UnaryMinus (g' v))
  g' (BinaryNoParens op v1 v2) = g (BinaryNoParens (g' op) (g' v1) (g' v2))
  g' (Parens v) = g (Parens (g' v))
  g' (OperatorSection op (Left v)) = g (OperatorSection (g' op) (Left $ g' v))
  g' (OperatorSection op (Right v)) = g (OperatorSection (g' op) (Right $ g' v))
  g' (TypeClassDictionaryConstructorApp name v) = g (TypeClassDictionaryConstructorApp name (g' v))
  g' (Accessor prop v) = g (Accessor prop (g' v))
  g' (ObjectUpdate obj vs) = g (ObjectUpdate (g' obj) (map (fmap g') vs))
  g' (Abs name v) = g (Abs name (g' v))
  g' (App v1 v2) = g (App (g' v1) (g' v2))
  g' (IfThenElse v1 v2 v3) = g (IfThenElse (g' v1) (g' v2) (g' v3))
  g' (Case vs alts) = g (Case (map g' vs) (map handleCaseAlternative alts))
  g' (TypedValue check v ty) = g (TypedValue check (g' v) ty)
  g' (Let ds v) = g (Let (map f' ds) (g' v))
  g' (Do es) = g (Do (map handleDoNotationElement es))
  g' (PositionedValue pos com v) = g (PositionedValue pos com (g' v))
  g' other = g other

  h' :: Binder -> Binder
  h' (ConstructorBinder ctor bs) = h (ConstructorBinder ctor (map h' bs))
  h' (BinaryNoParensBinder b1 b2 b3) = h (BinaryNoParensBinder (h' b1) (h' b2) (h' b3))
  h' (ParensInBinder b) = h (ParensInBinder (h' b))
  h' (LiteralBinder l) = h (LiteralBinder (lit h' l))
  h' (NamedBinder name b) = h (NamedBinder name (h' b))
  h' (PositionedBinder pos com b) = h (PositionedBinder pos com (h' b))
  h' (TypedBinder t b) = h (TypedBinder t (h' b))
  h' other = h other

  lit :: (a -> a) -> Literal a -> Literal a
  lit go (ArrayLiteral as) = ArrayLiteral (map go as)
  lit go (ObjectLiteral as) = ObjectLiteral (map (fmap go) as)
  lit _ other = other

  handleCaseAlternative :: CaseAlternative -> CaseAlternative
  handleCaseAlternative ca =
    ca { caseAlternativeBinders = map h' (caseAlternativeBinders ca)
       , caseAlternativeResult = (map (g' *** g') +++ g') (caseAlternativeResult ca)
       }

  handleDoNotationElement :: DoNotationElement -> DoNotationElement
  handleDoNotationElement (DoNotationValue v) = DoNotationValue (g' v)
  handleDoNotationElement (DoNotationBind b v) = DoNotationBind (h' b) (g' v)
  handleDoNotationElement (DoNotationLet ds) = DoNotationLet (map f' ds)
  handleDoNotationElement (PositionedDoNotationElement pos com e) = PositionedDoNotationElement pos com (handleDoNotationElement e)

everywhereOnValuesTopDownM
  :: forall m
   . (Monad m)
  => (Declaration -> m Declaration)
  -> (Expr -> m Expr)
  -> (Binder -> m Binder)
  -> ( Declaration -> m Declaration
     , Expr -> m Expr
     , Binder -> m Binder
     )
everywhereOnValuesTopDownM f g h = (f' <=< f, g' <=< g, h' <=< h)
  where

  f' :: Declaration -> m Declaration
  f' (DataBindingGroupDeclaration ds) = DataBindingGroupDeclaration <$> traverse (f' <=< f) ds
  f' (ValueDeclaration name nameKind bs val) = ValueDeclaration name nameKind <$> traverse (h' <=< h) bs <*> eitherM (traverse (pairM (g' <=< g) (g' <=< g))) (g' <=< g) val
  f' (BindingGroupDeclaration ds) = BindingGroupDeclaration <$> traverse (\(name, nameKind, val) -> (,,) name nameKind <$> (g val >>= g')) ds
  f' (TypeClassDeclaration name args implies ds) = TypeClassDeclaration name args implies <$> traverse (f' <=< f) ds
  f' (TypeInstanceDeclaration name cs className args ds) = TypeInstanceDeclaration name cs className args <$> traverseTypeInstanceBody (traverse (f' <=< f)) ds
  f' (PositionedDeclaration pos com d) = PositionedDeclaration pos com <$> (f d >>= f')
  f' other = f other

  g' :: Expr -> m Expr
  g' (Literal l) = Literal <$> lit (g >=> g') l
  g' (UnaryMinus v) = UnaryMinus <$> (g v >>= g')
  g' (BinaryNoParens op v1 v2) = BinaryNoParens <$> (g op >>= g') <*> (g v1 >>= g') <*> (g v2 >>= g')
  g' (Parens v) = Parens <$> (g v >>= g')
  g' (OperatorSection op (Left v)) = OperatorSection <$> (g op >>= g') <*> (Left <$> (g v >>= g'))
  g' (OperatorSection op (Right v)) = OperatorSection <$> (g op >>= g') <*> (Right <$> (g v >>= g'))
  g' (TypeClassDictionaryConstructorApp name v) = TypeClassDictionaryConstructorApp name <$> (g v >>= g')
  g' (Accessor prop v) = Accessor prop <$> (g v >>= g')
  g' (ObjectUpdate obj vs) = ObjectUpdate <$> (g obj >>= g') <*> traverse (sndM (g' <=< g)) vs
  g' (Abs name v) = Abs name <$> (g v >>= g')
  g' (App v1 v2) = App <$> (g v1 >>= g') <*> (g v2 >>= g')
  g' (IfThenElse v1 v2 v3) = IfThenElse <$> (g v1 >>= g') <*> (g v2 >>= g') <*> (g v3 >>= g')
  g' (Case vs alts) = Case <$> traverse (g' <=< g) vs <*> traverse handleCaseAlternative alts
  g' (TypedValue check v ty) = TypedValue check <$> (g v >>= g') <*> pure ty
  g' (Let ds v) = Let <$> traverse (f' <=< f) ds <*> (g v >>= g')
  g' (Do es) = Do <$> traverse handleDoNotationElement es
  g' (PositionedValue pos com v) = PositionedValue pos com <$> (g v >>= g')
  g' other = g other

  h' :: Binder -> m Binder
  h' (LiteralBinder l) = LiteralBinder <$> lit (h >=> h') l
  h' (ConstructorBinder ctor bs) = ConstructorBinder ctor <$> traverse (h' <=< h) bs
  h' (BinaryNoParensBinder b1 b2 b3) = BinaryNoParensBinder <$> (h b1 >>= h') <*> (h b2 >>= h') <*> (h b3 >>= h')
  h' (ParensInBinder b) = ParensInBinder <$> (h b >>= h')
  h' (NamedBinder name b) = NamedBinder name <$> (h b >>= h')
  h' (PositionedBinder pos com b) = PositionedBinder pos com <$> (h b >>= h')
  h' (TypedBinder t b) = TypedBinder t <$> (h b >>= h')
  h' other = h other

  lit :: (a -> m a) -> Literal a -> m (Literal a)
  lit go (ObjectLiteral as) = ObjectLiteral <$> traverse (sndM go) as
  lit go (ArrayLiteral as) = ArrayLiteral <$> traverse go as
  lit _ other = pure other

  handleCaseAlternative :: CaseAlternative -> m CaseAlternative
  handleCaseAlternative (CaseAlternative bs val) =
    CaseAlternative
      <$> traverse (h' <=< h) bs
      <*> eitherM (traverse (pairM (g' <=< g) (g' <=< g))) (g' <=< g) val

  handleDoNotationElement :: DoNotationElement -> m DoNotationElement
  handleDoNotationElement (DoNotationValue v) = DoNotationValue <$> (g' <=< g) v
  handleDoNotationElement (DoNotationBind b v) = DoNotationBind <$> (h' <=< h) b <*> (g' <=< g) v
  handleDoNotationElement (DoNotationLet ds) = DoNotationLet <$> traverse (f' <=< f) ds
  handleDoNotationElement (PositionedDoNotationElement pos com e) = PositionedDoNotationElement pos com <$> handleDoNotationElement e

everywhereOnValuesM
  :: forall m
   . (Monad m)
  => (Declaration -> m Declaration)
  -> (Expr -> m Expr)
  -> (Binder -> m Binder)
  -> ( Declaration -> m Declaration
     , Expr -> m Expr
     , Binder -> m Binder
     )
everywhereOnValuesM f g h = (f', g', h')
  where

  f' :: Declaration -> m Declaration
  f' (DataBindingGroupDeclaration ds) = (DataBindingGroupDeclaration <$> traverse f' ds) >>= f
  f' (ValueDeclaration name nameKind bs val) = (ValueDeclaration name nameKind <$> traverse h' bs <*> eitherM (traverse (pairM g' g')) g' val) >>= f
  f' (BindingGroupDeclaration ds) = (BindingGroupDeclaration <$> traverse (\(name, nameKind, val) -> (,,) name nameKind <$> g' val) ds) >>= f
  f' (TypeClassDeclaration name args implies ds) = (TypeClassDeclaration name args implies <$> traverse f' ds) >>= f
  f' (TypeInstanceDeclaration name cs className args ds) = (TypeInstanceDeclaration name cs className args <$> traverseTypeInstanceBody (traverse f') ds) >>= f
  f' (PositionedDeclaration pos com d) = (PositionedDeclaration pos com <$> f' d) >>= f
  f' other = f other

  g' :: Expr -> m Expr
  g' (Literal l) = (Literal <$> lit g' l) >>= g
  g' (UnaryMinus v) = (UnaryMinus <$> g' v) >>= g
  g' (BinaryNoParens op v1 v2) = (BinaryNoParens <$> g' op <*> g' v1 <*> g' v2) >>= g
  g' (Parens v) = (Parens <$> g' v) >>= g
  g' (OperatorSection op (Left v)) = (OperatorSection <$> g' op <*> (Left <$> g' v)) >>= g
  g' (OperatorSection op (Right v)) = (OperatorSection <$> g' op <*> (Right <$> g' v)) >>= g
  g' (TypeClassDictionaryConstructorApp name v) = (TypeClassDictionaryConstructorApp name <$> g' v) >>= g
  g' (Accessor prop v) = (Accessor prop <$> g' v) >>= g
  g' (ObjectUpdate obj vs) = (ObjectUpdate <$> g' obj <*> traverse (sndM g') vs) >>= g
  g' (Abs name v) = (Abs name <$> g' v) >>= g
  g' (App v1 v2) = (App <$> g' v1 <*> g' v2) >>= g
  g' (IfThenElse v1 v2 v3) = (IfThenElse <$> g' v1 <*> g' v2 <*> g' v3) >>= g
  g' (Case vs alts) = (Case <$> traverse g' vs <*> traverse handleCaseAlternative alts) >>= g
  g' (TypedValue check v ty) = (TypedValue check <$> g' v <*> pure ty) >>= g
  g' (Let ds v) = (Let <$> traverse f' ds <*> g' v) >>= g
  g' (Do es) = (Do <$> traverse handleDoNotationElement es) >>= g
  g' (PositionedValue pos com v) = (PositionedValue pos com <$> g' v) >>= g
  g' other = g other

  h' :: Binder -> m Binder
  h' (LiteralBinder l) = (LiteralBinder <$> lit h' l) >>= h
  h' (ConstructorBinder ctor bs) = (ConstructorBinder ctor <$> traverse h' bs) >>= h
  h' (BinaryNoParensBinder b1 b2 b3) = (BinaryNoParensBinder <$> h' b1 <*> h' b2 <*> h' b3) >>= h
  h' (ParensInBinder b) = (ParensInBinder <$> h' b) >>= h
  h' (NamedBinder name b) = (NamedBinder name <$> h' b) >>= h
  h' (PositionedBinder pos com b) = (PositionedBinder pos com <$> h' b) >>= h
  h' (TypedBinder t b) = (TypedBinder t <$> h' b) >>= h
  h' other = h other

  lit :: (a -> m a) -> Literal a -> m (Literal a)
  lit go (ObjectLiteral as) = ObjectLiteral <$> traverse (sndM go) as
  lit go (ArrayLiteral as) = ArrayLiteral <$> traverse go as
  lit _ other = pure other

  handleCaseAlternative :: CaseAlternative -> m CaseAlternative
  handleCaseAlternative (CaseAlternative bs val) =
    CaseAlternative
      <$> traverse h' bs
      <*> eitherM (traverse (pairM g' g')) g' val

  handleDoNotationElement :: DoNotationElement -> m DoNotationElement
  handleDoNotationElement (DoNotationValue v) = DoNotationValue <$> g' v
  handleDoNotationElement (DoNotationBind b v) = DoNotationBind <$> h' b <*> g' v
  handleDoNotationElement (DoNotationLet ds) = DoNotationLet <$> traverse f' ds
  handleDoNotationElement (PositionedDoNotationElement pos com e) = PositionedDoNotationElement pos com <$> handleDoNotationElement e

everythingOnValues
  :: forall r
   . (r -> r -> r)
  -> (Declaration -> r)
  -> (Expr -> r)
  -> (Binder -> r)
  -> (CaseAlternative -> r)
  -> (DoNotationElement -> r)
  -> ( Declaration -> r
     , Expr -> r
     , Binder -> r
     , CaseAlternative -> r
     , DoNotationElement -> r
     )
everythingOnValues (<>) f g h i j = (f', g', h', i', j')
  where

  f' :: Declaration -> r
  f' d@(DataBindingGroupDeclaration ds) = foldl (<>) (f d) (map f' ds)
  f' d@(ValueDeclaration _ _ bs (Right val)) = foldl (<>) (f d) (map h' bs) <> g' val
  f' d@(ValueDeclaration _ _ bs (Left gs)) = foldl (<>) (f d) (map h' bs ++ concatMap (\(grd, val) -> [g' grd, g' val]) gs)
  f' d@(BindingGroupDeclaration ds) = foldl (<>) (f d) (map (\(_, _, val) -> g' val) ds)
  f' d@(TypeClassDeclaration _ _ _ ds) = foldl (<>) (f d) (map f' ds)
  f' d@(TypeInstanceDeclaration _ _ _ _ (ExplicitInstance ds)) = foldl (<>) (f d) (map f' ds)
  f' d@(PositionedDeclaration _ _ d1) = f d <> f' d1
  f' d = f d

  g' :: Expr -> r
  g' v@(Literal l) = lit (g v) g' l
  g' v@(UnaryMinus v1) = g v <> g' v1
  g' v@(BinaryNoParens op v1 v2) = g v <> g' op <> g' v1 <> g' v2
  g' v@(Parens v1) = g v <> g' v1
  g' v@(OperatorSection op (Left v1)) = g v <> g' op <> g' v1
  g' v@(OperatorSection op (Right v1)) = g v <> g' op <> g' v1
  g' v@(TypeClassDictionaryConstructorApp _ v1) = g v <> g' v1
  g' v@(Accessor _ v1) = g v <> g' v1
  g' v@(ObjectUpdate obj vs) = foldl (<>) (g v <> g' obj) (map (g' . snd) vs)
  g' v@(Abs _ v1) = g v <> g' v1
  g' v@(App v1 v2) = g v <> g' v1 <> g' v2
  g' v@(IfThenElse v1 v2 v3) = g v <> g' v1 <> g' v2 <> g' v3
  g' v@(Case vs alts) = foldl (<>) (foldl (<>) (g v) (map g' vs)) (map i' alts)
  g' v@(TypedValue _ v1 _) = g v <> g' v1
  g' v@(Let ds v1) = foldl (<>) (g v) (map f' ds) <> g' v1
  g' v@(Do es) = foldl (<>) (g v) (map j' es)
  g' v@(PositionedValue _ _ v1) = g v <> g' v1
  g' v = g v

  h' :: Binder -> r
  h' b@(LiteralBinder l) = lit (h b) h' l
  h' b@(ConstructorBinder _ bs) = foldl (<>) (h b) (map h' bs)
  h' b@(BinaryNoParensBinder b1 b2 b3) = h b <> h' b1 <> h' b2 <> h' b3
  h' b@(ParensInBinder b1) = h b <> h' b1
  h' b@(NamedBinder _ b1) = h b <> h' b1
  h' b@(PositionedBinder _ _ b1) = h b <> h' b1
  h' b@(TypedBinder _ b1) = h b <> h' b1
  h' b = h b

  lit :: r -> (a -> r) -> Literal a -> r
  lit r go (ArrayLiteral as) = foldl (<>) r (map go as)
  lit r go (ObjectLiteral as) = foldl (<>) r (map (go . snd) as)
  lit r _ _ = r

  i' :: CaseAlternative -> r
  i' ca@(CaseAlternative bs (Right val)) = foldl (<>) (i ca) (map h' bs) <> g' val
  i' ca@(CaseAlternative bs (Left gs)) = foldl (<>) (i ca) (map h' bs ++ concatMap (\(grd, val) -> [g' grd, g' val]) gs)

  j' :: DoNotationElement -> r
  j' e@(DoNotationValue v) = j e <> g' v
  j' e@(DoNotationBind b v) = j e <> h' b <> g' v
  j' e@(DoNotationLet ds) = foldl (<>) (j e) (map f' ds)
  j' e@(PositionedDoNotationElement _ _ e1) = j e <> j' e1

everythingWithContextOnValues
  :: forall s r
   . s
  -> r
  -> (r -> r -> r)
  -> (s -> Declaration       -> (s, r))
  -> (s -> Expr              -> (s, r))
  -> (s -> Binder            -> (s, r))
  -> (s -> CaseAlternative   -> (s, r))
  -> (s -> DoNotationElement -> (s, r))
  -> ( Declaration       -> r
     , Expr              -> r
     , Binder            -> r
     , CaseAlternative   -> r
     , DoNotationElement -> r)
everythingWithContextOnValues s0 r0 (<>) f g h i j = (f'' s0, g'' s0, h'' s0, i'' s0, j'' s0)
  where

  f'' :: s -> Declaration -> r
  f'' s d = let (s', r) = f s d in r <> f' s' d

  f' :: s -> Declaration -> r
  f' s (DataBindingGroupDeclaration ds) = foldl (<>) r0 (map (f'' s) ds)
  f' s (ValueDeclaration _ _ bs (Right val)) = foldl (<>) r0 (map (h'' s) bs) <> g'' s val
  f' s (ValueDeclaration _ _ bs (Left gs)) = foldl (<>) r0 (map (h'' s) bs ++ concatMap (\(grd, val) -> [g'' s grd, g'' s val]) gs)
  f' s (BindingGroupDeclaration ds) = foldl (<>) r0 (map (\(_, _, val) -> g'' s val) ds)
  f' s (TypeClassDeclaration _ _ _ ds) = foldl (<>) r0 (map (f'' s) ds)
  f' s (TypeInstanceDeclaration _ _ _ _ (ExplicitInstance ds)) = foldl (<>) r0 (map (f'' s) ds)
  f' s (PositionedDeclaration _ _ d1) = f'' s d1
  f' _ _ = r0

  g'' :: s -> Expr -> r
  g'' s v = let (s', r) = g s v in r <> g' s' v

  g' :: s -> Expr -> r
  g' s (Literal l) = lit g'' s l
  g' s (UnaryMinus v1) = g'' s v1
  g' s (BinaryNoParens op v1 v2) = g'' s op <> g'' s v1 <> g'' s v2
  g' s (Parens v1) = g'' s v1
  g' s (OperatorSection op (Left v)) = g'' s op <> g'' s v
  g' s (OperatorSection op (Right v)) = g'' s op <> g'' s v
  g' s (TypeClassDictionaryConstructorApp _ v1) = g'' s v1
  g' s (Accessor _ v1) = g'' s v1
  g' s (ObjectUpdate obj vs) = foldl (<>) (g'' s obj) (map (g'' s . snd) vs)
  g' s (Abs _ v1) = g'' s v1
  g' s (App v1 v2) = g'' s v1 <> g'' s v2
  g' s (IfThenElse v1 v2 v3) = g'' s v1 <> g'' s v2 <> g'' s v3
  g' s (Case vs alts) = foldl (<>) (foldl (<>) r0 (map (g'' s) vs)) (map (i'' s) alts)
  g' s (TypedValue _ v1 _) = g'' s v1
  g' s (Let ds v1) = foldl (<>) r0 (map (f'' s) ds) <> g'' s v1
  g' s (Do es) = foldl (<>) r0 (map (j'' s) es)
  g' s (PositionedValue _ _ v1) = g'' s v1
  g' _ _ = r0

  h'' :: s -> Binder -> r
  h'' s b = let (s', r) = h s b in r <> h' s' b

  h' :: s -> Binder -> r
  h' s (LiteralBinder l) = lit h'' s l
  h' s (ConstructorBinder _ bs) = foldl (<>) r0 (map (h'' s) bs)
  h' s (BinaryNoParensBinder b1 b2 b3) = h'' s b1 <> h'' s b2 <> h'' s b3
  h' s (ParensInBinder b) = h'' s b
  h' s (NamedBinder _ b1) = h'' s b1
  h' s (PositionedBinder _ _ b1) = h'' s b1
  h' s (TypedBinder _ b1) = h'' s b1
  h' _ _ = r0

  lit :: (s -> a -> r) -> s -> Literal a -> r
  lit go s (ArrayLiteral as) = foldl (<>) r0 (map (go s) as)
  lit go s (ObjectLiteral as) = foldl (<>) r0 (map (go s . snd) as)
  lit _ _ _ = r0

  i'' :: s -> CaseAlternative -> r
  i'' s ca = let (s', r) = i s ca in r <> i' s' ca

  i' :: s -> CaseAlternative -> r
  i' s (CaseAlternative bs (Right val)) = foldl (<>) r0 (map (h'' s) bs) <> g'' s val
  i' s (CaseAlternative bs (Left gs)) = foldl (<>) r0 (map (h'' s) bs ++ concatMap (\(grd, val) -> [g'' s grd, g'' s val]) gs)

  j'' :: s -> DoNotationElement -> r
  j'' s e = let (s', r) = j s e in r <> j' s' e

  j' :: s -> DoNotationElement -> r
  j' s (DoNotationValue v) = g'' s v
  j' s (DoNotationBind b v) = h'' s b <> g'' s v
  j' s (DoNotationLet ds) = foldl (<>) r0 (map (f'' s) ds)
  j' s (PositionedDoNotationElement _ _ e1) = j'' s e1

everywhereWithContextOnValuesM
  :: forall m s
   . (Monad m)
  => s
  -> (s -> Declaration       -> m (s, Declaration))
  -> (s -> Expr              -> m (s, Expr))
  -> (s -> Binder            -> m (s, Binder))
  -> (s -> CaseAlternative   -> m (s, CaseAlternative))
  -> (s -> DoNotationElement -> m (s, DoNotationElement))
  -> ( Declaration       -> m Declaration
     , Expr              -> m Expr
     , Binder            -> m Binder
     , CaseAlternative   -> m CaseAlternative
     , DoNotationElement -> m DoNotationElement)
everywhereWithContextOnValuesM s0 f g h i j = (f'' s0, g'' s0, h'' s0, i'' s0, j'' s0)
  where
  f'' s = uncurry f' <=< f s

  f' s (DataBindingGroupDeclaration ds) = DataBindingGroupDeclaration <$> traverse (f'' s) ds
  f' s (ValueDeclaration name nameKind bs val) = ValueDeclaration name nameKind <$> traverse (h'' s) bs <*> eitherM (traverse (pairM (g'' s) (g'' s))) (g'' s) val
  f' s (BindingGroupDeclaration ds) = BindingGroupDeclaration <$> traverse (thirdM (g'' s)) ds
  f' s (TypeClassDeclaration name args implies ds) = TypeClassDeclaration name args implies <$> traverse (f'' s) ds
  f' s (TypeInstanceDeclaration name cs className args ds) = TypeInstanceDeclaration name cs className args <$> traverseTypeInstanceBody (traverse (f'' s)) ds
  f' s (PositionedDeclaration pos com d1) = PositionedDeclaration pos com <$> f'' s d1
  f' _ other = return other

  g'' s = uncurry g' <=< g s

  g' s (Literal l) = Literal <$> lit g'' s l
  g' s (UnaryMinus v) = UnaryMinus <$> g'' s v
  g' s (BinaryNoParens op v1 v2) = BinaryNoParens <$> g'' s op <*> g'' s v1 <*> g'' s v2
  g' s (Parens v) = Parens <$> g'' s v
  g' s (OperatorSection op (Left v)) = OperatorSection <$> g'' s op <*> (Left <$> g'' s v)
  g' s (OperatorSection op (Right v)) = OperatorSection <$> g'' s op <*> (Right <$> g'' s v)
  g' s (TypeClassDictionaryConstructorApp name v) = TypeClassDictionaryConstructorApp name <$> g'' s v
  g' s (Accessor prop v) = Accessor prop <$> g'' s v
  g' s (ObjectUpdate obj vs) = ObjectUpdate <$> g'' s obj <*> traverse (sndM (g'' s)) vs
  g' s (Abs name v) = Abs name <$> g'' s v
  g' s (App v1 v2) = App <$> g'' s v1 <*> g'' s v2
  g' s (IfThenElse v1 v2 v3) = IfThenElse <$> g'' s v1 <*> g'' s v2 <*> g'' s v3
  g' s (Case vs alts) = Case <$> traverse (g'' s) vs <*> traverse (i'' s) alts
  g' s (TypedValue check v ty) = TypedValue check <$> g'' s v <*> pure ty
  g' s (Let ds v) = Let <$> traverse (f'' s) ds <*> g'' s v
  g' s (Do es) = Do <$> traverse (j'' s) es
  g' s (PositionedValue pos com v) = PositionedValue pos com <$> g'' s v
  g' _ other = return other

  h'' s = uncurry h' <=< h s

  h' s (LiteralBinder l) = LiteralBinder <$> lit h'' s l
  h' s (ConstructorBinder ctor bs) = ConstructorBinder ctor <$> traverse (h'' s) bs
  h' s (BinaryNoParensBinder b1 b2 b3) = BinaryNoParensBinder <$> h'' s b1 <*> h'' s b2 <*> h'' s b3
  h' s (ParensInBinder b) = ParensInBinder <$> h'' s b
  h' s (NamedBinder name b) = NamedBinder name <$> h'' s b
  h' s (PositionedBinder pos com b) = PositionedBinder pos com <$> h'' s b
  h' s (TypedBinder t b) = TypedBinder t <$> h'' s b
  h' _ other = return other

  lit :: (s -> a -> m a) -> s -> Literal a -> m (Literal a)
  lit go s (ArrayLiteral as) = ArrayLiteral <$> traverse (go s) as
  lit go s (ObjectLiteral as) = ObjectLiteral <$> traverse (sndM (go s)) as
  lit _ _ other = return other

  i'' s = uncurry i' <=< i s

  i' s (CaseAlternative bs val) = CaseAlternative <$> traverse (h'' s) bs <*> eitherM (traverse (pairM (g'' s) (g'' s))) (g'' s) val

  j'' s = uncurry j' <=< j s

  j' s (DoNotationValue v) = DoNotationValue <$> g'' s v
  j' s (DoNotationBind b v) = DoNotationBind <$> h'' s b <*> g'' s v
  j' s (DoNotationLet ds) = DoNotationLet <$> traverse (f'' s) ds
  j' s (PositionedDoNotationElement pos com e1) = PositionedDoNotationElement pos com <$> j'' s e1

everythingWithScope
  :: forall r
   . (Monoid r)
  => (S.Set Ident -> Declaration -> r)
  -> (S.Set Ident -> Expr -> r)
  -> (S.Set Ident -> Binder -> r)
  -> (S.Set Ident -> CaseAlternative -> r)
  -> (S.Set Ident -> DoNotationElement -> r)
  -> ( S.Set Ident -> Declaration -> r
     , S.Set Ident -> Expr -> r
     , S.Set Ident -> Binder -> r
     , S.Set Ident -> CaseAlternative -> r
     , S.Set Ident -> DoNotationElement -> r
     )
everythingWithScope f g h i j = (f'', g'', h'', i'', \s -> snd . j'' s)
  where
  -- Avoid importing Data.Monoid and getting shadowed names above
  (<>) = mappend

  f'' :: S.Set Ident -> Declaration -> r
  f'' s a = f s a <> f' s a

  f' :: S.Set Ident -> Declaration -> r
  f' s (DataBindingGroupDeclaration ds) =
    let s' = S.union s (S.fromList (mapMaybe getDeclIdent ds))
    in foldMap (f'' s') ds
  f' s (ValueDeclaration name _ bs (Right val)) =
    let s' = S.insert name s
    in foldMap (h'' s') bs <> g'' s' val
  f' s (ValueDeclaration name _ bs (Left gs)) =
    let s' = S.insert name s
        s'' = S.union s' (S.fromList (concatMap binderNames bs))
    in foldMap (h'' s') bs <> foldMap (\(grd, val) -> g'' s'' grd <> g'' s'' val) gs
  f' s (BindingGroupDeclaration ds) =
    let s' = S.union s (S.fromList (map (\(name, _, _) -> name) ds))
    in foldMap (\(_, _, val) -> g'' s' val) ds
  f' s (TypeClassDeclaration _ _ _ ds) = foldMap (f'' s) ds
  f' s (TypeInstanceDeclaration _ _ _ _ (ExplicitInstance ds)) = foldMap (f'' s) ds
  f' s (PositionedDeclaration _ _ d) = f'' s d
  f' _ _ = mempty

  g'' :: S.Set Ident -> Expr -> r
  g'' s a = g s a <> g' s a

  g' :: S.Set Ident -> Expr -> r
  g' s (Literal l) = lit g'' s l
  g' s (UnaryMinus v1) = g'' s v1
  g' s (BinaryNoParens op v1 v2) = g'' s op <> g'' s v1 <> g'' s v2
  g' s (Parens v1) = g'' s v1
  g' s (OperatorSection op (Left v)) = g'' s op <> g'' s v
  g' s (OperatorSection op (Right v)) = g'' s op <> g'' s v
  g' s (TypeClassDictionaryConstructorApp _ v1) = g'' s v1
  g' s (Accessor _ v1) = g'' s v1
  g' s (ObjectUpdate obj vs) = g'' s obj <> foldMap (g'' s . snd) vs
  g' s (Abs (Left name) v1) =
    let s' = S.insert name s
    in g'' s' v1
  g' s (Abs (Right b) v1) =
    let s' = S.union (S.fromList (binderNames b)) s
    in g'' s' v1
  g' s (App v1 v2) = g'' s v1 <> g'' s v2
  g' s (IfThenElse v1 v2 v3) = g'' s v1 <> g'' s v2 <> g'' s v3
  g' s (Case vs alts) = foldMap (g'' s) vs <> foldMap (i'' s) alts
  g' s (TypedValue _ v1 _) = g'' s v1
  g' s (Let ds v1) =
    let s' = S.union s (S.fromList (mapMaybe getDeclIdent ds))
    in foldMap (f'' s') ds <> g'' s' v1
  g' s (Do es) = fold . snd . mapAccumL j'' s $ es
  g' s (PositionedValue _ _ v1) = g'' s v1
  g' _ _ = mempty

  h'' :: S.Set Ident -> Binder -> r
  h'' s a = h s a <> h' s a

  h' :: S.Set Ident -> Binder -> r
  h' s (LiteralBinder l) = lit h'' s l
  h' s (ConstructorBinder _ bs) = foldMap (h'' s) bs
  h' s (BinaryNoParensBinder b1 b2 b3) = foldMap (h'' s) [b1, b2, b3]
  h' s (ParensInBinder b) = h'' s b
  h' s (NamedBinder name b1) = h'' (S.insert name s) b1
  h' s (PositionedBinder _ _ b1) = h'' s b1
  h' s (TypedBinder _ b1) = h'' s b1
  h' _ _ = mempty

  lit :: (S.Set Ident -> a -> r) -> S.Set Ident -> Literal a -> r
  lit go s (ArrayLiteral as) = foldMap (go s) as
  lit go s (ObjectLiteral as) = foldMap (go s . snd) as
  lit _ _ _ = mempty

  i'' :: S.Set Ident -> CaseAlternative -> r
  i'' s a = i s a <> i' s a

  i' :: S.Set Ident -> CaseAlternative -> r
  i' s (CaseAlternative bs (Right val)) =
    let s' = S.union s (S.fromList (concatMap binderNames bs))
    in foldMap (h'' s) bs <> g'' s' val
  i' s (CaseAlternative bs (Left gs)) =
    let s' = S.union s (S.fromList (concatMap binderNames bs))
    in foldMap (h'' s) bs <> foldMap (\(grd, val) -> g'' s' grd <> g'' s' val) gs

  j'' :: S.Set Ident -> DoNotationElement -> (S.Set Ident, r)
  j'' s a = let (s', r) = j' s a in (s', j s a <> r)

  j' :: S.Set Ident -> DoNotationElement -> (S.Set Ident, r)
  j' s (DoNotationValue v) = (s, g'' s v)
  j' s (DoNotationBind b v) =
    let s' = S.union (S.fromList (binderNames b)) s
    in (s', h'' s b <> g'' s' v)
  j' s (DoNotationLet ds) =
    let s' = S.union s (S.fromList (mapMaybe getDeclIdent ds))
    in (s', foldMap (f'' s') ds)
  j' s (PositionedDoNotationElement _ _ e1) = j'' s e1

  getDeclIdent :: Declaration -> Maybe Ident
  getDeclIdent (PositionedDeclaration _ _ d) = getDeclIdent d
  getDeclIdent (ValueDeclaration ident _ _ _) = Just ident
  getDeclIdent (TypeDeclaration ident _) = Just ident
  getDeclIdent _ = Nothing

accumTypes
  :: (Monoid r)
  => (Type -> r)
  -> ( Declaration -> r
     , Expr -> r
     , Binder -> r
     , CaseAlternative -> r
     , DoNotationElement -> r
     )
accumTypes f = everythingOnValues mappend forDecls forValues (const mempty) (const mempty) (const mempty)
  where
  forDecls (DataDeclaration _ _ _ dctors) = mconcat (concatMap (map f . snd) dctors)
  forDecls (ExternDeclaration _ ty) = f ty
  forDecls (TypeClassDeclaration _ _ implies _) = mconcat (concatMap (map f . snd) implies)
  forDecls (TypeInstanceDeclaration _ cs _ tys _) = mconcat (concatMap (map f . snd) cs) `mappend` mconcat (map f tys)
  forDecls (TypeSynonymDeclaration _ _ ty) = f ty
  forDecls (TypeDeclaration _ ty) = f ty
  forDecls _ = mempty

  forValues (TypeClassDictionary (_, cs) _) = mconcat (map f cs)
  forValues (SuperClassDictionary _ tys) = mconcat (map f tys)
  forValues (TypedValue _ _ ty) = f ty
  forValues _ = mempty
