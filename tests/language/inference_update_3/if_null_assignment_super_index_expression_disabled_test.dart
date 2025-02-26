// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Tests the absence of the functionality proposed in
// https://github.com/dart-lang/language/issues/1618#issuecomment-1507241494
// when the `inference-update-3` language feature is not enabled, using if-null
// assignments whose target is an index expression whose target is `super`.

// @dart=3.3

import '../static_type_helper.dart';

/// Ensures a context type of `Iterable<T>` for the operand, or `Iterable<_>` if
/// no type argument is supplied.
Object? contextIterable<T>(Iterable<T> x) => x;

class A {}

class B1<T> implements A {}

class B2<T> implements A {}

class C1<T> implements B1<T>, B2<T> {}

class C2<T> implements B1<T>, B2<T> {}

class CallableClass<T> {
  T call() => throw '';
}

/// Class that can be the target of `[]` and `[]=` operations. [ReadType] and
/// [WriteType] are the read and write types of the `[]` and `[]=` operators,
/// respectively.
class Indexable<ReadType, WriteType> {
  final ReadType _value;

  Indexable(this._value);

  ReadType operator [](int index) => _value;

  operator []=(int index, WriteType value) {}
}

// - An if-null assignment `E` of the form `e1 ??= e2` with context type `K` is
//   analyzed as follows:
//
//   - Let `T1` be the read type of `e1`. This is the static type that `e1`
//     would have as an expression with a context type schema of `_`.
//   - Let `T2` be the type of `e2` inferred with context type `J`, where:
//     - If the lvalue is a local variable, `J` is the current (possibly
//       promoted) type of the variable.
//     - Otherwise, `J` is the write type `e1`. This is the type schema that the
//       setter associated with `e1` imposes on its single argument (or, for the
//       case of indexed assignment, the type schema that `operator[]=` imposes
//       on its second argument).
//
// Check the context type of `e`.
class Test1 extends Indexable<String, Object?> {
  Test1() : super('');
  test() {
    // ignore: dead_null_aware_expression
    super[0] ??= contextType('')..expectStaticType<Exactly<Object?>>();
  }
}

class Test2 extends Indexable<String?, String?> {
  Test2() : super(null);
  test() {
    super[0] ??= contextType('')..expectStaticType<Exactly<String?>>();
  }
}

//   - Let `J'` be the unpromoted write type of `e1`, defined as follows:
//     - If `e1` is a local variable, `J'` is the declared (unpromoted) type of
//       `e1`.
//     - Otherwise `J' = J`.
//   - Let `T2'` be the coerced type of `e2`, defined as follows:
//     - If `T2` is a subtype of `J'`, then `T2' = T2` (no coercion is needed).
//     - Otherwise, if `T2` can be coerced to a some other type which *is* a
//       subtype of `J'`, then apply that coercion and let `T2'` be the type
//       resulting from the coercion.
//     - Otherwise, it is a compile-time error.
//   - Let `T` be `UP(NonNull(T1), T2')`.
//   - Let `S` be the greatest closure of `K`.
//   - If `T <: S`, then the type of `E` is `T`.
class Test3 extends Indexable<int?, Object?> {
  Test3() : super(null);
  test() {
    // K=Object, T1=int?, and T2'=double, therefore T=num and S=Object, so T <:
    // S, and hence the type of E is num.
    var d = 2.0;
    context<Object>((super[0] ??= d)..expectStaticType<Exactly<num>>());
  }
}

class Test4 extends Indexable<Iterable<int>?, Object?> {
  Test4() : super(null);
  test() {
    // K=Iterable<_>, T1=Iterable<int>?, and T2'=Iterable<double>, therefore
    // T=Iterable<num> and S=Iterable<Object?>, so T <: S, and hence the type of
    // E is Iterable<num>.
    var iterableDouble = <double>[] as Iterable<double>;
    contextIterable((super[0] ??= iterableDouble)
      ..expectStaticType<Exactly<Iterable<num>>>());
  }
}

class Test5 extends Indexable<Function?, Function?> {
  Test5() : super(null);
  test() {
    // K=Function, T1=Function?, and T2'=int Function() (coerced from
    // T2=CallableClass<int>), therefore T=Function and S=Function, so T <: S,
    // and hence the type of E is Function.
    var callableClassInt = CallableClass<int>();
    context<Function>(
        (super[0] ??= callableClassInt)..expectStaticType<Exactly<Function>>());
  }
}

//   - Otherwise, if `NonNull(T1) <: S` and `T2' <: S`, then the type of `E` is
//     `S` if `inference-update-3` is enabled, else the type of `E` is `T`.
class Test6 extends Indexable<Iterable<int>?, Object?> {
  Test6() : super(null);
  test() {
    // K=Iterable<num>, T1=Iterable<int>?, and T2'=List<num>, therefore T=Object
    // and S=Iterable<num>, so T is not <: S, but NonNull(T1) <: S and T2' <: S,
    // hence the type of E is Object.
    var listNum = <num>[];
    var o = [0] as Object?;
    if (o is Iterable<num>) {
      // We avoid having a compile-time error because `o` can be demoted.
      o = (super[0] ??= listNum)..expectStaticType<Exactly<Object>>();
    }
  }
}

class Test7 extends Indexable<C1<int> Function()?, Function?> {
  Test7() : super(null);
  test() {
    // K=B1<int> Function(), T1=C1<int> Function()?, and T2'=C2<int> Function()
    // (coerced from T2=CallableClass<C2<int>>), therefore T=A Function() and
    // S=B1<int> Function(), so T is not <: S, but NonNull(T1) <: S and T2' <:
    // S, hence the type of E is A Function().
    var callableClassC2Int = CallableClass<C2<int>>();
    var o = (() => B1<int>()) as Object?;
    if (o is B1<int> Function()) {
      // We avoid having a compile-time error because `o` can be demoted.
      o = (super[0] ??= callableClassC2Int)
        ..expectStaticType<Exactly<A Function()>>();
    }
  }
}

//   - Otherwise, the type of `E` is `T`.
class Test8 extends Indexable<int?, Object?> {
  Test8() : super(null);
  test() {
    var d = 2.0;
    var o = 0 as Object?;
    if (o is int?) {
      // K=int?, T1=int?, and T2'=double, therefore T=num and S=int?, so T is
      // not <: S. NonNull(T1) <: S, but T2' is not <: S. Hence the type of E is
      // num.
      // We avoid having a compile-time error because `o` can be demoted.
      o = (super[0] ??= d)..expectStaticType<Exactly<num>>();
    }
  }
}

class Test9 extends Indexable<double?, Object?> {
  Test9() : super(null);
  test() {
    var intQuestion = null as int?;
    var o = 0 as Object?;
    if (o is int?) {
      // K=int?, T1=double?, and T2'=int?, therefore T=num? and S=int?, so T is
      // not <: S. T2' <: S, but NonNull(T1) is not <: S. Hence the type of E is
      // num?.
      // We avoid having a compile-time error because `o` can be demoted.
      o = (super[0] ??= intQuestion)..expectStaticType<Exactly<num?>>();
    }
  }
}

class Test10 extends Indexable<int?, Object?> {
  Test10() : super(null);
  test() {
    var d = 2.0;
    var o = '' as Object?;
    if (o is String?) {
      // K=String?, T1=int?, and T2'=double, therefore T=num and S=String?, so
      // none of T, NonNull(T1), nor T2' are <: S. Hence the type of E is num.
      // We avoid having a compile-time error because `o` can be demoted.
      o = (super[0] ??= d)..expectStaticType<Exactly<num>>();
    }
  }
}

class Test11 extends Indexable<C1<int> Function()?, Function?> {
  Test11() : super(null);
  test() {
    var callableClassC2Int = CallableClass<C2<int>>();
    var o = (() => C1<int>()) as Object?;
    if (o is C1<int> Function()) {
      // K=C1<int> Function(), T1=C1<int> Function()?, and T2'=C2<int>
      // Function() (coerced from T2=CallableClass<C2<int>>), therefore T=A
      // Function() and S=C1<int> Function(), so T is not <: S. NonNull(T1) <:
      // S, but T2' is not <: S. Hence the type of E is A Function().
      // We avoid having a compile-time error because `o` can be demoted.
      o = (super[0] ??= callableClassC2Int)
        ..expectStaticType<Exactly<A Function()>>();
    }
  }
}

class Test12 extends Indexable<C1<int> Function()?, Function?> {
  Test12() : super(null);
  test() {
    var callableClassC2Int = CallableClass<C2<int>>();
    var o = (() => C2<int>()) as Object?;
    if (o is C2<int> Function()) {
      // K=C2<int> Function(), T1=C1<int> Function()?, and T2'=C2<int>
      // Function() (coerced from T2=CallableClass<C2<int>>), therefore T=A
      // Function() and S=C2<int> Function(), so T is not <: S. T2' <: S, but
      // NonNull(T1) is not <: S. Hence the type of E is A Function().
      // We avoid having a compile-time error because `o` can be demoted.
      o = (super[0] ??= callableClassC2Int)
        ..expectStaticType<Exactly<A Function()>>();
    }
  }
}

class Test13 extends Indexable<C1<int> Function()?, Function?> {
  Test13() : super(null);
  test() {
    var callableClassC2Int = CallableClass<C2<int>>();
    var o = 0 as Object?;
    if (o is int) {
      // K=int, T1=C1<int> Function()?, and T2'=C2<int> Function() (coerced from
      // T2=CallableClass<C2<int>>), therefore T=A Function() and S=int, so T is
      // not <: S. T2' <: S, but NonNull(T1) is not <: S. Hence the type of E is
      // A Function().
      // We avoid having a compile-time error because `o` can be demoted.
      o = (super[0] ??= callableClassC2Int)
        ..expectStaticType<Exactly<A Function()>>();
    }
  }
}

main() {
  Test1().test();
  Test2().test();
  Test3().test();
  Test4().test();
  Test5().test();
  Test6().test();
  Test7().test();
  Test8().test();
  Test9().test();
  Test10().test();
  Test11().test();
  Test12().test();
  Test13().test();
}
