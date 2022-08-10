// Copyright (c) 2022, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/dart/element/member.dart'; // ignore: implementation_imports
import 'package:collection/collection.dart';

import 'util/dart_type_utilities.dart';

extension ElementExtension on Element {
  Element get canonicalElement {
    var self = this;
    if (self is PropertyAccessorElement) {
      var variable = self.variable;
      if (variable is FieldMember) {
        // A field element defined in a parameterized type where the values of
        // the type parameters are known.
        //
        // This concept should be invisible when comparing FieldElements, but a
        // bug in the analyzer causes FieldElements to not evaluate as
        // equivalent to equivalent FieldMembers. See
        // https://github.com/dart-lang/sdk/issues/35343.
        return variable.declaration;
      } else {
        return variable;
      }
    } else {
      return self;
    }
  }
}

class EnumLikeClassDescription {
  final Map<DartObject, Set<FieldElement>> _enumConstants;
  EnumLikeClassDescription(this._enumConstants);

  /// Returns a fresh map of the class's enum-like constant values.
  Map<DartObject, Set<FieldElement>> get enumConstants => {..._enumConstants};
}

extension ClassElementExtension on ClassElement {
  /// Returns an [EnumLikeClassDescription] for this if the latter is a valid
  /// "enum-like" class.
  ///
  /// An enum-like class must meet the following requirements:
  ///
  /// * is concrete,
  /// * has no public constructors,
  /// * has no factory constructors,
  /// * has two or more static const fields with the same type as the class,
  /// * has no subclasses declared in the defining library.
  ///
  /// The returned [EnumLikeClassDescription]'s `enumConstantNames` contains all
  /// of the static const fields with the same type as the class, with one
  /// exception; any static const field which is marked `@Deprecated` and is
  /// equal to another static const field with the same type as the class is not
  /// included. Such a field is assumed to be deprecated in favor of the field
  /// with equal value.
  EnumLikeClassDescription? get asEnumLikeClass {
    // See discussion: https://github.com/dart-lang/linter/issues/2083.

    // Must be concrete.
    if (isAbstract) {
      return null;
    }

    // With only private non-factory constructors.
    for (var constructor in constructors) {
      if (!constructor.isPrivate || constructor.isFactory) {
        return null;
      }
    }

    var type = thisType;

    // And 2 or more static const fields whose type is the enclosing class.
    var enumConstantCount = 0;
    var enumConstants = <DartObject, Set<FieldElement>>{};
    for (var field in fields) {
      // Ensure static const.
      if (field.isSynthetic || !field.isConst || !field.isStatic) {
        continue;
      }
      // Check for type equality.
      if (field.type != type) {
        continue;
      }
      var fieldValue = field.computeConstantValue();
      if (fieldValue == null) {
        continue;
      }
      enumConstantCount++;
      enumConstants.putIfAbsent(fieldValue, () => {}).add(field);
    }
    if (enumConstantCount < 2) {
      return null;
    }

    // And no subclasses in the defining library.
    if (hasSubclassInDefiningCompilationUnit) return null;

    return EnumLikeClassDescription(enumConstants);
  }

  bool get hasSubclassInDefiningCompilationUnit {
    var compilationUnit = library.definingCompilationUnit;
    for (var cls in compilationUnit.classes) {
      InterfaceType? classType = cls.thisType;
      do {
        classType = classType?.superclass;
        if (classType == thisType) {
          return true;
        }
      } while (classType != null && !classType.isDartCoreObject);
    }
    return false;
  }

  /// Returns whether this class is exactly [otherName] declared in
  /// [otherLibrary].
  bool isClass(String otherName, String otherLibrary) =>
      name == otherName && library.name == otherLibrary;

  bool get isEnumLikeClass => asEnumLikeClass != null;
}

extension InterfaceElementExtension on InterfaceElement {
  /// Returns whether this element is exactly [otherName] declared in
  /// [otherLibrary].
  bool isClass(String otherName, String otherLibrary) =>
      name == otherName && library.name == otherLibrary;
}

extension NullableAstNodeExtension on AstNode? {
  Element? get canonicalElement {
    var self = this;
    if (self is Expression) {
      var node = self.unParenthesized;
      if (node is Identifier) {
        return node.staticElement?.canonicalElement;
      } else if (node is PropertyAccess) {
        return node.propertyName.staticElement?.canonicalElement;
      }
    }
    return null;
  }
}

extension AstNodeExtension on AstNode {
  /// Builds the list resulting from traversing the node in DFS and does not
  /// include the node itself.
  ///
  /// It excludes the nodes for which the [excludeCriteria] returns true. If
  /// [excludeCriteria] is not provided, all nodes are included.
  Iterable<AstNode> traverseNodesInDFS({AstNodePredicate? excludeCriteria}) {
    var nodes = <AstNode>{};
    var nodesToVisit = List.of(childNodes);
    if (excludeCriteria == null) {
      while (nodesToVisit.isNotEmpty) {
        var node = nodesToVisit.removeAt(0);
        nodes.add(node);
        nodesToVisit.insertAll(0, node.childNodes);
      }
    } else {
      while (nodesToVisit.isNotEmpty) {
        var node = nodesToVisit.removeAt(0);
        if (excludeCriteria(node)) continue;
        nodes.add(node);
        nodesToVisit.insertAll(0, node.childNodes);
      }
    }

    return nodes;
  }

  Iterable<AstNode> get childNodes => childEntities.whereType<AstNode>();
}

extension BlockExtension on Block {
  /// Returns the last statement of this block, or `null` if this is empty.
  ///
  /// If the last immediate statement of this block is a [Block], recurses into
  /// it to find the last statement.
  Statement? get lastStatement {
    if (statements.isEmpty) {
      return null;
    }
    var lastStatement = statements.last;
    if (lastStatement is Block) {
      return lastStatement.lastStatement;
    }
    return lastStatement;
  }
}

extension ClassMemberListExtension on List<ClassMember> {
  MethodDeclaration? getMethod(String name) => whereType<MethodDeclaration>()
      .firstWhereOrNull((node) => node.name2.lexeme == name);
}

extension DartTypeExtension on DartType? {
  bool extendsClass(String? className, String library) {
    var self = this;
    if (self is InterfaceType) {
      return _extendsClass(self, <InterfaceElement>{}, className, library);
    }
    return false;
  }

  static bool _extendsClass(
          InterfaceType? type,
          Set<InterfaceElement> seenElements,
          String? className,
          String? library) =>
      type != null &&
      seenElements.add(type.element2) &&
      (DartTypeUtilities.isClass(type, className, library) ||
          _extendsClass(type.superclass, seenElements, className, library));
}

extension ExpressionExtension on Expression? {
  bool get isNullLiteral => this?.unParenthesized is NullLiteral;
}

extension InterfaceTypeExtension on InterfaceType {
  /// Returns the collection of all interfaces that this type implements,
  /// including itself.
  Iterable<InterfaceType> get implementedInterfaces {
    void searchSupertypes(
        InterfaceType? type,
        Set<InterfaceElement> alreadyVisited,
        List<InterfaceType> interfaceTypes) {
      if (type == null || !alreadyVisited.add(type.element2)) {
        return;
      }
      interfaceTypes.add(type);
      searchSupertypes(type.superclass, alreadyVisited, interfaceTypes);
      for (var interface in type.interfaces) {
        searchSupertypes(interface, alreadyVisited, interfaceTypes);
      }
      for (var mixin in type.mixins) {
        searchSupertypes(mixin, alreadyVisited, interfaceTypes);
      }
    }

    var interfaceTypes = <InterfaceType>[];
    searchSupertypes(this, {}, interfaceTypes);
    return interfaceTypes;
  }
}

extension MethodDeclarationExtension on MethodDeclaration {
  /// Returns whether this method is an override of a method in any supertype.
  bool get isOverride {
    var name = declaredElement2?.name;
    if (name == null) {
      return false;
    }
    var parentElement = declaredElement2?.enclosingElement3;
    if (parentElement is! InterfaceElement) {
      return false;
    }
    var parentLibrary = parentElement.library;

    if (isGetter) {
      // Search supertypes for a getter of the same name.
      return parentElement.allSupertypes
          .any((t) => t.lookUpGetter2(name, parentLibrary) != null);
    } else if (isSetter) {
      // Search supertypes for a setter of the same name.
      return parentElement.allSupertypes
          .any((t) => t.lookUpSetter2(name, parentLibrary) != null);
    } else {
      // Search supertypes for a method of the same name.
      return parentElement.allSupertypes
          .any((t) => t.lookUpMethod2(name, parentLibrary) != null);
    }
  }
}