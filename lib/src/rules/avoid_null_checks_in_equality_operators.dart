// Copyright (c) 2017, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';

import '../analyzer.dart';
import '../extensions.dart';
import '../util/dart_type_utilities.dart';

const _desc = r"Don't check for null in custom == operators.";

const _details = r'''

**DON'T** check for null in custom == operators.

As null is a special type, no class can be equivalent to it.  Thus, it is
redundant to check whether the other instance is null. 

**BAD:**
```dart
class Person {
  final String name;

  @override
  operator ==(other) =>
      other != null && other is Person && name == other.name;
}
```

**GOOD:**
```dart
class Person {
  final String name;

  @override
  operator ==(other) => other is Person && name == other.name;
}
```

''';

bool _isComparingEquality(TokenType tokenType) =>
    tokenType == TokenType.BANG_EQ || tokenType == TokenType.EQ_EQ;

bool _isComparingParameterWithNull(BinaryExpression node, Element? parameter) =>
    _isComparingEquality(node.operator.type) &&
    ((node.leftOperand.isNullLiteral &&
            _isParameter(node.rightOperand, parameter)) ||
        (node.rightOperand.isNullLiteral &&
            _isParameter(node.leftOperand, parameter)));

bool _isParameter(Expression expression, Element? parameter) =>
    expression.canonicalElement == parameter;

bool _isParameterWithQuestion(AstNode node, Element? parameter) =>
    (node is PropertyAccess &&
        node.operator.type == TokenType.QUESTION_PERIOD &&
        node.target.canonicalElement == parameter) ||
    (node is MethodInvocation &&
        node.operator?.type == TokenType.QUESTION_PERIOD &&
        node.target.canonicalElement == parameter);

bool _isParameterWithQuestionQuestion(
        BinaryExpression node, Element? parameter) =>
    node.operator.type == TokenType.QUESTION_QUESTION &&
    _isParameter(node.leftOperand, parameter);

class AvoidNullChecksInEqualityOperators extends LintRule {
  AvoidNullChecksInEqualityOperators()
      : super(
            name: 'avoid_null_checks_in_equality_operators',
            description: _desc,
            details: _details,
            group: Group.style);

  @override
  void registerNodeProcessors(
      NodeLintRegistry registry, LinterContext context) {
    var visitor =
        _Visitor(this, nnbdEnabled: context.isEnabled(Feature.non_nullable));
    registry.addMethodDeclaration(this, visitor);
  }
}

class _Visitor extends SimpleAstVisitor<void> {
  final LintRule rule;
  final bool nnbdEnabled;

  _Visitor(this.rule, {required this.nnbdEnabled});

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    var parameters = node.parameters?.parameters;
    if (parameters == null) {
      return;
    }

    if (node.name.token.type != TokenType.EQ_EQ || parameters.length != 1) {
      return;
    }

    var parameter = parameters.first.identifier.canonicalElement;

    // Analyzer will produce UNNECESSARY_NULL_COMPARISON_FALSE|TRUE
    // See: https://github.com/dart-lang/linter/issues/2864
    if (nnbdEnabled &&
        parameter is VariableElement &&
        parameter.type.nullabilitySuffix != NullabilitySuffix.question) {
      return;
    }

    bool checkIfParameterIsNull(AstNode node) =>
        _isParameterWithQuestion(node, parameter) ||
        (node is BinaryExpression &&
            (_isParameterWithQuestionQuestion(node, parameter) ||
                _isComparingParameterWithNull(node, parameter)));

    DartTypeUtilities.traverseNodesInDFS(node.body)
        .where(checkIfParameterIsNull)
        .forEach(rule.reportLint);
  }
}
