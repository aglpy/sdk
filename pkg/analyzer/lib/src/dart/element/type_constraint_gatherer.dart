// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:_fe_analyzer_shared/src/type_inference/type_analyzer_operations.dart'
    show TypeDeclarationKind;
import 'package:_fe_analyzer_shared/src/type_inference/type_constraint.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/dart/ast/ast.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/element/type.dart';
import 'package:analyzer/src/dart/element/type_algebra.dart';
import 'package:analyzer/src/dart/element/type_schema.dart';
import 'package:analyzer/src/dart/element/type_system.dart';
import 'package:analyzer/src/dart/resolver/flow_analysis_visitor.dart';

/// Creates sets of [TypeConstraint]s for type parameters, based on an attempt
/// to make one type schema a subtype of another.
class TypeConstraintGatherer {
  final TypeSystemImpl _typeSystem;
  final Set<TypeParameterElement> _typeParameters = Set.identity();
  final List<
      GeneratedTypeConstraint<DartType, DartType, TypeParameterElement,
          PromotableElement>> _constraints = [];
  final TypeSystemOperations _typeSystemOperations;
  final TypeConstraintGenerationDataForTesting? dataForTesting;

  TypeConstraintGatherer({
    required TypeSystemImpl typeSystem,
    required Iterable<TypeParameterElement> typeParameters,
    required TypeSystemOperations typeSystemOperations,
    required this.dataForTesting,
  })  : _typeSystem = typeSystem,
        _typeSystemOperations = typeSystemOperations {
    _typeParameters.addAll(typeParameters);
  }

  bool get isConstraintSetEmpty => _constraints.isEmpty;

  /// Returns the set of type constraints that was gathered.
  Map<
      TypeParameterElement,
      MergedTypeConstraint<DartType, DartType, TypeParameterElement,
          PromotableElement>> computeConstraints() {
    var result = <TypeParameterElement,
        MergedTypeConstraint<DartType, DartType, TypeParameterElement,
            PromotableElement>>{};
    for (var parameter in _typeParameters) {
      result[parameter] = MergedTypeConstraint<DartType, DartType,
          TypeParameterElement, PromotableElement>(
        lower: UnknownInferredType.instance,
        upper: UnknownInferredType.instance,
        origin: const UnknownTypeConstraintOrigin(),
      );
    }

    for (var constraint in _constraints) {
      var parameter = constraint.typeParameter;
      var mergedConstraint = result[parameter]!;

      mergedConstraint.mergeIn(constraint, _typeSystemOperations);
    }

    return result;
  }

  /// Tries to match [P] as a subtype for [Q].
  ///
  /// If the match succeeds, the resulting type constraints are recorded for
  /// later use by [computeConstraints].  If the match fails, the set of type
  /// constraints is unchanged.
  bool trySubtypeMatch(DartType P, DartType Q, bool leftSchema,
      {required AstNode? nodeForTesting}) {
    // If `P` is `_` then the match holds with no constraints.
    if (_typeSystemOperations.isUnknownType(P)) {
      return true;
    }

    // If `Q` is `_` then the match holds with no constraints.
    if (_typeSystemOperations.isUnknownType(Q)) {
      return true;
    }

    // If `P` is a type variable `X` in `L`, then the match holds:
    //   Under constraint `_ <: X <: Q`.
    var P_nullability = _typeSystemOperations.getNullabilitySuffix(P);
    if (_typeSystemOperations.isTypeParameterType(P) &&
        P_nullability == NullabilitySuffix.none &&
        _typeParameters.contains(P.element)) {
      _addUpper(P.element as TypeParameterElement, Q,
          nodeForTesting: nodeForTesting);
      return true;
    }

    // If `Q` is a type variable `X` in `L`, then the match holds:
    //   Under constraint `P <: X <: _`.
    var Q_nullability = _typeSystemOperations.getNullabilitySuffix(Q);
    if (_typeSystemOperations.isTypeParameterType(Q) &&
        Q_nullability == NullabilitySuffix.none &&
        _typeParameters.contains(Q.element)) {
      _addLower(Q.element as TypeParameterElement, P,
          nodeForTesting: nodeForTesting);
      return true;
    }

    // If `P` and `Q` are identical types, then the subtype match holds
    // under no constraints.
    if (P == Q) {
      return true;
    }

    // If `Q` is `FutureOr<Q0>` the match holds under constraint set `C`:
    if (_typeSystemOperations.matchFutureOr(Q) case var Q0?
        when Q_nullability == NullabilitySuffix.none) {
      var rewind = _constraints.length;

      // If `P` is `FutureOr<P0>` and `P0` is a subtype match for `Q0` under
      // constraint set `C`.
      if (_typeSystemOperations.matchFutureOr(P) case var P0?
          when P_nullability == NullabilitySuffix.none) {
        if (trySubtypeMatch(P0, Q0, leftSchema,
            nodeForTesting: nodeForTesting)) {
          return true;
        }
        _constraints.length = rewind;
      }

      // Or if `P` is a subtype match for `Future<Q0>` under non-empty
      // constraint set `C`.
      var futureQ0 = _futureNone(Q0);
      var P_matches_FutureQ0 = trySubtypeMatch(P, futureQ0, leftSchema,
          nodeForTesting: nodeForTesting);
      if (P_matches_FutureQ0 && _constraints.length != rewind) {
        return true;
      }
      _constraints.length = rewind;

      // Or if `P` is a subtype match for `Q0` under constraint set `C`.
      if (trySubtypeMatch(P, Q0, leftSchema, nodeForTesting: nodeForTesting)) {
        return true;
      }
      _constraints.length = rewind;

      // Or if `P` is a subtype match for `Future<Q0>` under empty
      // constraint set `C`.
      if (P_matches_FutureQ0) {
        return true;
      }
    }

    // If `Q` is `Q0?` the match holds under constraint set `C`:
    if (Q_nullability == NullabilitySuffix.question) {
      var Q0 = _typeSystemOperations.withNullabilitySuffix(
          Q, NullabilitySuffix.none);
      var rewind = _constraints.length;

      // If `P` is `P0?` and `P0` is a subtype match for `Q0` under
      // constraint set `C`.
      if (P_nullability == NullabilitySuffix.question) {
        var P0 = _typeSystemOperations.withNullabilitySuffix(
            P, NullabilitySuffix.none);
        if (trySubtypeMatch(P0, Q0, leftSchema,
            nodeForTesting: nodeForTesting)) {
          return true;
        }
        _constraints.length = rewind;
      }

      // Or if `P` is `dynamic` or `void` and `Object` is a subtype match
      // for `Q0` under constraint set `C`.
      if (_typeSystemOperations.isDynamic(P) ||
          _typeSystemOperations.isVoid(P)) {
        if (trySubtypeMatch(_typeSystem.objectNone, Q0, leftSchema,
            nodeForTesting: nodeForTesting)) {
          return true;
        }
        _constraints.length = rewind;
      }

      // Or if `P` is a subtype match for `Q0` under non-empty
      // constraint set `C`.
      var P_matches_Q0 =
          trySubtypeMatch(P, Q0, leftSchema, nodeForTesting: nodeForTesting);
      if (P_matches_Q0 && _constraints.length != rewind) {
        return true;
      }
      _constraints.length = rewind;

      // Or if `P` is a subtype match for `Null` under constraint set `C`.
      if (trySubtypeMatch(P, _typeSystem.nullNone, leftSchema,
          nodeForTesting: nodeForTesting)) {
        return true;
      }
      _constraints.length = rewind;

      // Or if `P` is a subtype match for `Q0` under empty
      // constraint set `C`.
      if (P_matches_Q0) {
        return true;
      }
    }

    // If `P` is `FutureOr<P0>` the match holds under constraint set `C1 + C2`:
    if (_typeSystemOperations.matchFutureOr(P) case var P0?
        when P_nullability == NullabilitySuffix.none) {
      var rewind = _constraints.length;

      // If `Future<P0>` is a subtype match for `Q` under constraint set `C1`.
      // And if `P0` is a subtype match for `Q` under constraint set `C2`.
      var future_P0 = _futureNone(P0);
      if (trySubtypeMatch(future_P0, Q, leftSchema,
              nodeForTesting: nodeForTesting) &&
          trySubtypeMatch(P0, Q, leftSchema, nodeForTesting: nodeForTesting)) {
        return true;
      }

      _constraints.length = rewind;
    }

    // If `P` is `P0?` the match holds under constraint set `C1 + C2`:
    if (P_nullability == NullabilitySuffix.question) {
      var P0 = _typeSystemOperations.withNullabilitySuffix(
          P, NullabilitySuffix.none);
      var rewind = _constraints.length;

      // If `P0` is a subtype match for `Q` under constraint set `C1`.
      // And if `Null` is a subtype match for `Q` under constraint set `C2`.
      if (trySubtypeMatch(P0, Q, leftSchema, nodeForTesting: nodeForTesting) &&
          trySubtypeMatch(_typeSystem.nullNone, Q, leftSchema,
              nodeForTesting: nodeForTesting)) {
        return true;
      }

      _constraints.length = rewind;
    }

    // If `Q` is `dynamic`, `Object?`, or `void` then the match holds under
    // no constraints.
    if (_typeSystemOperations.isDynamic(Q) ||
        _typeSystemOperations.isVoid(Q) ||
        Q == _typeSystemOperations.objectQuestionType) {
      return true;
    }

    // If `P` is `Never` then the match holds under no constraints.
    if (_typeSystemOperations.isNever(P)) {
      return true;
    }

    // If `Q` is `Object`, then the match holds under no constraints:
    //  Only if `P` is non-nullable.
    if (Q == _typeSystemOperations.objectType) {
      return _typeSystem.isNonNullable(P);
    }

    // If `P` is `Null`, then the match holds under no constraints:
    //  Only if `Q` is nullable.
    if (P_nullability == NullabilitySuffix.none &&
        _typeSystemOperations.isNull(P)) {
      return _typeSystem.isNullable(Q);
    }

    // If `P` is a type variable `X` with bound `B` (or a promoted type
    // variable `X & B`), the match holds with constraint set `C`:
    //   If `B` is a subtype match for `Q` with constraint set `C`.
    // Note: we have already eliminated the case that `X` is a variable in `L`.
    if (P_nullability == NullabilitySuffix.none && P is TypeParameterTypeImpl) {
      var rewind = _constraints.length;
      var B = P.promotedBound ?? P.element.bound;
      if (B != null &&
          trySubtypeMatch(B, Q, leftSchema, nodeForTesting: nodeForTesting)) {
        return true;
      }
      _constraints.length = rewind;
    }

    TypeDeclarationKind? P_typeDeclarationKind =
        _typeSystemOperations.getTypeDeclarationKind(P);
    TypeDeclarationKind? Q_typeDeclarationKind =
        _typeSystemOperations.getTypeDeclarationKind(Q);
    if (P_typeDeclarationKind == TypeDeclarationKind.interfaceDeclaration &&
        Q_typeDeclarationKind == TypeDeclarationKind.interfaceDeclaration) {
      // If `P` is `C<M0, ..., Mk> and `Q` is `C<N0, ..., Nk>`, then the match
      // holds under constraints `C0 + ... + Ck`:
      //   If `Mi` is a subtype match for `Ni` with respect to L under
      //   constraints `Ci`.
      if (P.element == Q.element) {
        if (!_interfaceType_arguments(
            P as InterfaceType, Q as InterfaceType, leftSchema,
            nodeForTesting: nodeForTesting)) {
          return false;
        }
        return true;
      }
      return _interfaceType(P as InterfaceType, Q as InterfaceType, leftSchema,
          nodeForTesting: nodeForTesting);
    } else if (P_typeDeclarationKind ==
            TypeDeclarationKind.extensionTypeDeclaration &&
        Q_typeDeclarationKind == TypeDeclarationKind.extensionTypeDeclaration) {
      // If `P` is `C<M0, ..., Mk> and `Q` is `C<N0, ..., Nk>`, then the match
      // holds under constraints `C0 + ... + Ck`:
      //   If `Mi` is a subtype match for `Ni` with respect to L under
      //   constraints `Ci`.
      if (P.element == Q.element) {
        if (!_interfaceType_arguments(
            P as InterfaceType, Q as InterfaceType, leftSchema,
            nodeForTesting: nodeForTesting)) {
          return false;
        }
        return true;
      }
      return _interfaceType(P as InterfaceType, Q as InterfaceType, leftSchema,
          nodeForTesting: nodeForTesting);
    }

    if (P_typeDeclarationKind != null && Q_typeDeclarationKind != null) {
      return _interfaceType(P as InterfaceType, Q as InterfaceType, leftSchema,
          nodeForTesting: nodeForTesting);
    }

    // If `Q` is `Function` then the match holds under no constraints:
    //   If `P` is a function type.
    if (Q_nullability == NullabilitySuffix.none && Q.isDartCoreFunction) {
      if (_typeSystemOperations.isFunctionType(P)) {
        return true;
      }
    }

    if (_typeSystemOperations.isFunctionType(P) &&
        _typeSystemOperations.isFunctionType(Q)) {
      return _functionType(P as FunctionType, Q as FunctionType, leftSchema,
          nodeForTesting: nodeForTesting);
    }

    // A type `P` is a subtype match for `Record` with respect to `L` under no
    // constraints:
    //   If `P` is a record type or `Record`.
    if (Q_nullability == NullabilitySuffix.none && Q.isDartCoreRecord) {
      if (_typeSystemOperations.isRecordType(P)) {
        return true;
      }
    }

    if (_typeSystemOperations.isRecordType(P) &&
        _typeSystemOperations.isRecordType(Q)) {
      return _recordType(P as RecordTypeImpl, Q as RecordTypeImpl, leftSchema,
          nodeForTesting: nodeForTesting);
    }

    return false;
  }

  void _addLower(TypeParameterElement element, DartType lower,
      {required AstNode? nodeForTesting}) {
    GeneratedTypeConstraint<DartType, DartType, TypeParameterElement,
            PromotableElement> generatedTypeConstraint =
        GeneratedTypeConstraint<DartType, DartType, TypeParameterElement,
            PromotableElement>.lower(element, lower);
    _constraints.add(generatedTypeConstraint);
    if (dataForTesting != null && nodeForTesting != null) {
      (dataForTesting!.generatedTypeConstraints[nodeForTesting] ??= [])
          .add(generatedTypeConstraint);
    }
  }

  void _addUpper(TypeParameterElement element, DartType upper,
      {required AstNode? nodeForTesting}) {
    GeneratedTypeConstraint<DartType, DartType, TypeParameterElement,
            PromotableElement> generatedTypeConstraint =
        GeneratedTypeConstraint<DartType, DartType, TypeParameterElement,
            PromotableElement>.upper(element, upper);
    _constraints.add(generatedTypeConstraint);
    if (dataForTesting != null && nodeForTesting != null) {
      (dataForTesting!.generatedTypeConstraints[nodeForTesting] ??= [])
          .add(generatedTypeConstraint);
    }
  }

  bool _functionType(FunctionType P, FunctionType Q, bool leftSchema,
      {required AstNode? nodeForTesting}) {
    if (P.nullabilitySuffix != NullabilitySuffix.none) {
      return false;
    }

    if (Q.nullabilitySuffix != NullabilitySuffix.none) {
      return false;
    }

    var P_typeFormals = P.typeFormals;
    var Q_typeFormals = Q.typeFormals;
    if (P_typeFormals.length != Q_typeFormals.length) {
      return false;
    }

    if (P_typeFormals.isEmpty && Q_typeFormals.isEmpty) {
      return _functionType0(P, Q, leftSchema, nodeForTesting: nodeForTesting);
    }

    // We match two generic function types:
    // `<T0 extends B00, ..., Tn extends B0n>F0`
    // `<S0 extends B10, ..., Sn extends B1n>F1`
    // with respect to `L` under constraint set `C2`:
    var rewind = _constraints.length;

    // If `B0i` is a subtype match for `B1i` with constraint set `Ci0`.
    // If `B1i` is a subtype match for `B0i` with constraint set `Ci1`.
    // And `Ci2` is `Ci0 + Ci1`.
    for (var i = 0; i < P_typeFormals.length; i++) {
      var B0 = P_typeFormals[i].bound ?? _typeSystem.objectQuestion;
      var B1 = Q_typeFormals[i].bound ?? _typeSystem.objectQuestion;
      if (!trySubtypeMatch(B0, B1, leftSchema,
          nodeForTesting: nodeForTesting)) {
        _constraints.length = rewind;
        return false;
      }
      if (!trySubtypeMatch(B1, B0, !leftSchema,
          nodeForTesting: nodeForTesting)) {
        _constraints.length = rewind;
        return false;
      }
    }

    // And `Z0...Zn` are fresh variables with bounds `B20, ..., B2n`.
    //   Where `B2i` is `B0i[Z0/T0, ..., Zn/Tn]` if `P` is a type schema.
    //   Or `B2i` is `B1i[Z0/S0, ..., Zn/Sn]` if `Q` is a type schema.
    // In other words, we choose the bounds for the fresh variables from
    // whichever of the two generic function types is a type schema and does
    // not contain any variables from `L`.
    var newTypeParameters = <TypeParameterElement>[];
    for (var i = 0; i < P_typeFormals.length; i++) {
      var Z = TypeParameterElementImpl('Z$i', -1);
      if (leftSchema) {
        Z.bound = P_typeFormals[i].bound;
      } else {
        Z.bound = Q_typeFormals[i].bound;
      }
      newTypeParameters.add(Z);
    }

    // And `F0[Z0/T0, ..., Zn/Tn]` is a subtype match for
    // `F1[Z0/S0, ..., Zn/Sn]` with respect to `L` under constraints `C0`.
    var typeArguments = newTypeParameters
        .map((e) => e.instantiate(nullabilitySuffix: NullabilitySuffix.none))
        .toList();
    var P_instantiated = P.instantiate(typeArguments);
    var Q_instantiated = Q.instantiate(typeArguments);
    if (!_functionType0(P_instantiated, Q_instantiated, leftSchema,
        nodeForTesting: nodeForTesting)) {
      _constraints.length = rewind;
      return false;
    }

    // And `C1` is `C02 + ... + Cn2 + C0`.
    // And `C2` is `C1` with each constraint replaced with its closure
    // with respect to `[Z0, ..., Zn]`.
    // TODO(scheglov): do closure

    return true;
  }

  /// A function type `(M0,..., Mn, [M{n+1}, ..., Mm]) -> R0` is a subtype
  /// match for a function type `(N0,..., Nk, [N{k+1}, ..., Nr]) -> R1` with
  /// respect to `L` under constraints `C0 + ... + Cr + C`.
  bool _functionType0(FunctionType f, FunctionType g, bool leftSchema,
      {required AstNode? nodeForTesting}) {
    var rewind = _constraints.length;

    // If `R0` is a subtype match for a type `R1` with respect to `L` under
    // constraints `C`.
    if (!trySubtypeMatch(f.returnType, g.returnType, leftSchema,
        nodeForTesting: nodeForTesting)) {
      _constraints.length = rewind;
      return false;
    }

    var fParameters = f.parameters;
    var gParameters = g.parameters;

    // And for `i` in `0...r`, `Ni` is a subtype match for `Mi` with respect
    // to `L` under constraints `Ci`.
    var fIndex = 0;
    var gIndex = 0;
    while (fIndex < fParameters.length && gIndex < gParameters.length) {
      var fParameter = fParameters[fIndex];
      var gParameter = gParameters[gIndex];
      if (fParameter.isRequiredPositional) {
        if (gParameter.isRequiredPositional) {
          if (trySubtypeMatch(gParameter.type, fParameter.type, leftSchema,
              nodeForTesting: nodeForTesting)) {
            fIndex++;
            gIndex++;
          } else {
            _constraints.length = rewind;
            return false;
          }
        } else {
          _constraints.length = rewind;
          return false;
        }
      } else if (fParameter.isOptionalPositional) {
        if (gParameter.isPositional) {
          if (trySubtypeMatch(gParameter.type, fParameter.type, leftSchema,
              nodeForTesting: nodeForTesting)) {
            fIndex++;
            gIndex++;
          } else {
            _constraints.length = rewind;
            return false;
          }
        } else {
          _constraints.length = rewind;
          return false;
        }
      } else if (fParameter.isNamed) {
        if (gParameter.isNamed) {
          var compareNames = fParameter.name.compareTo(gParameter.name);
          if (compareNames == 0) {
            if (trySubtypeMatch(gParameter.type, fParameter.type, leftSchema,
                nodeForTesting: nodeForTesting)) {
              fIndex++;
              gIndex++;
            } else {
              _constraints.length = rewind;
              return false;
            }
          } else if (compareNames < 0) {
            if (fParameter.isRequiredNamed) {
              _constraints.length = rewind;
              return false;
            } else {
              fIndex++;
            }
          } else {
            assert(compareNames > 0);
            // The subtype must accept all parameters of the supertype.
            _constraints.length = rewind;
            return false;
          }
        } else {
          break;
        }
      }
    }

    // The supertype must provide all required parameters to the subtype.
    while (fIndex < fParameters.length) {
      var fParameter = fParameters[fIndex++];
      if (fParameter.isRequired) {
        _constraints.length = rewind;
        return false;
      }
    }

    // The subtype must accept all parameters of the supertype.
    assert(fIndex == fParameters.length);
    if (gIndex < gParameters.length) {
      _constraints.length = rewind;
      return false;
    }

    return true;
  }

  InterfaceType _futureNone(DartType valueType) {
    var element = _typeSystem.typeProvider.futureElement;
    return element.instantiate(
      typeArguments: fixedTypeList(valueType),
      nullabilitySuffix: NullabilitySuffix.none,
    );
  }

  bool _interfaceType(InterfaceType P, InterfaceType Q, bool leftSchema,
      {required AstNode? nodeForTesting}) {
    if (P.nullabilitySuffix != NullabilitySuffix.none) {
      return false;
    }

    if (Q.nullabilitySuffix != NullabilitySuffix.none) {
      return false;
    }

    // If `P` is `C0<M0, ..., Mk>` and `Q` is `C1<N0, ..., Nj>` then the match
    // holds with respect to `L` under constraints `C`:
    //   If `C1<B0, ..., Bj>` is a superinterface of `C0<M0, ..., Mk>` and
    //   `C1<B0, ..., Bj>` is a subtype match for `C1<N0, ..., Nj>` with
    //   respect to `L` under constraints `C`.
    var C0 = P.element;
    var C1 = Q.element;
    for (var interface in C0.allSupertypes) {
      if (interface.element == C1) {
        var substitution = Substitution.fromInterfaceType(P);
        return _interfaceType_arguments(
            substitution.substituteType(interface) as InterfaceType,
            Q,
            leftSchema,
            nodeForTesting: nodeForTesting);
      }
    }

    return false;
  }

  /// Match arguments of [P] against arguments of [Q].
  /// If returns `false`, the constraints are unchanged.
  bool _interfaceType_arguments(
      InterfaceType P, InterfaceType Q, bool leftSchema,
      {required AstNode? nodeForTesting}) {
    assert(P.element == Q.element);

    var rewind = _constraints.length;

    for (var i = 0; i < P.typeArguments.length; i++) {
      var variance =
          (P.element.typeParameters[i] as TypeParameterElementImpl).variance;
      var M = P.typeArguments[i];
      var N = Q.typeArguments[i];
      if ((variance.isCovariant || variance.isInvariant) &&
          !trySubtypeMatch(M, N, leftSchema, nodeForTesting: nodeForTesting)) {
        _constraints.length = rewind;
        return false;
      }
      if ((variance.isContravariant || variance.isInvariant) &&
          !trySubtypeMatch(N, M, leftSchema, nodeForTesting: nodeForTesting)) {
        _constraints.length = rewind;
        return false;
      }
    }

    return true;
  }

  /// If `P` is `(M0, ..., Mk)` and `Q` is `(N0, ..., Nk)`, then the match
  /// holds under constraints `C0 + ... + Ck`:
  ///   If `Mi` is a subtype match for `Ni` with respect to L under
  ///   constraints `Ci`.
  bool _recordType(RecordTypeImpl P, RecordTypeImpl Q, bool leftSchema,
      {required AstNode? nodeForTesting}) {
    if (P.nullabilitySuffix != NullabilitySuffix.none) {
      return false;
    }

    if (Q.nullabilitySuffix != NullabilitySuffix.none) {
      return false;
    }

    final positionalP = P.positionalFields;
    final positionalQ = Q.positionalFields;
    if (positionalP.length != positionalQ.length) {
      return false;
    }

    final namedP = P.namedFields;
    final namedQ = Q.namedFields;
    if (namedP.length != namedQ.length) {
      return false;
    }

    final rewind = _constraints.length;

    for (var i = 0; i < positionalP.length; i++) {
      final fieldP = positionalP[i];
      final fieldQ = positionalQ[i];
      if (!trySubtypeMatch(fieldP.type, fieldQ.type, leftSchema,
          nodeForTesting: nodeForTesting)) {
        _constraints.length = rewind;
        return false;
      }
    }

    for (var i = 0; i < namedP.length; i++) {
      final fieldP = namedP[i];
      final fieldQ = namedQ[i];
      if (fieldP.name != fieldQ.name) {
        _constraints.length = rewind;
        return false;
      }
      if (!trySubtypeMatch(fieldP.type, fieldQ.type, leftSchema,
          nodeForTesting: nodeForTesting)) {
        _constraints.length = rewind;
        return false;
      }
    }

    return true;
  }
}

/// Data structure maintaining intermediate type inference results, such as
/// type constraints, for testing purposes.  Under normal execution, no
/// instance of this class should be created.
class TypeConstraintGenerationDataForTesting {
  /// Map from nodes requiring type inference to the generated type constraints
  /// for the node.
  final Map<
      AstNode,
      List<
          GeneratedTypeConstraint<DartType, DartType, TypeParameterElement,
              PromotableElement>>> generatedTypeConstraints = {};

  /// Merges [other] into the receiver, combining the constraints.
  ///
  /// The method reuses data structures from [other] whenever possible, to
  /// avoid extra memory allocations. This process is destructive to [other]
  /// because the changes made to the reused structures will be visible to
  /// [other].
  void mergeIn(TypeConstraintGenerationDataForTesting other) {
    for (AstNode node in other.generatedTypeConstraints.keys) {
      List<
          GeneratedTypeConstraint<DartType, DartType, TypeParameterElement,
              PromotableElement>>? constraints = generatedTypeConstraints[node];
      if (constraints != null) {
        constraints.addAll(other.generatedTypeConstraints[node]!);
      } else {
        generatedTypeConstraints[node] = other.generatedTypeConstraints[node]!;
      }
    }
  }
}
