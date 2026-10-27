import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Lays its children out **in order, each into what the budget has left** —
/// where the budget is simply the `maxHeight` this widget is given.
///
/// ## Why this is not a `Column`
///
/// **A `Column` hands every non-flex child *unbounded* height**, so a child
/// inside one cannot find out how much room the parent has, and a size
/// budget written for it is arithmetic nobody consults — it reads as
/// enforced, the tests pass, and nothing says no until a widget grows. Task
/// 11.149 wrote such a bound for the app shell's banners, measured it doing
/// nothing at all, and this render object is what replaced it. Task 11.165
/// swept the app for the same shape and lifted it here so there is one of it
/// rather than two.
///
/// `Flexible` is not the answer either: it splits the budget by flex factor
/// rather than serving the children in a priority order, and a `Flexible`
/// beside an `Expanded` leaves a gap when the flexible child takes less than
/// its share. A [MultiChildLayoutDelegate] cannot do it at all — its
/// `getSize` is not allowed to depend on its children, so the region would
/// always occupy the whole budget even when the children are shorter.
///
/// ## What it guarantees, and what it does not
///
/// **Nothing here predicts a child's height.** Each child is laid out under a
/// real `maxHeight` and reports what it took; the next child is given the
/// difference. That is why there is no `heightFor` in this file and no number
/// that can drift away from what is drawn.
///
/// **A child that ignores the height it is given still overflows.** This
/// widget imposes the bound; honouring it is the child's half of the
/// contract, and the caller says in its own file what its children do when
/// the room runs out. **Given an unbounded `maxHeight` — a widget test
/// pumping a screen with no surface — there is no bound at all and every
/// child renders in full.** Failing open is right: the bound exists to
/// protect something from these children, and there is nothing to protect.
///
/// ## The two rules a shedding child has to obey
///
/// Written for the app shell's banners by task 11.149 and re-homed here by
/// task 11.189, which deleted that shell surface and would otherwise have
/// left the Record screen's pinned bar quoting rules from a file that no
/// longer exists.
///
/// 1. **Over the bound, a child shows as many whole lines as the height it
///    is given holds, and ellipsises the rest.** It never silently clips: an
///    ellipsis is the sign that there is more, and a clipped sentence is the
///    failure nobody reports because nobody can see it.
/// 2. **If even one line does not fit, the child stands down** — it renders
///    nothing at all rather than a stripe or a sliver. A sliver of something
///    with no readable word in it is furniture that costs space and tells
///    nobody anything.
///
/// **[BudgetedColumn] does not enforce either of them**, and saying so is the
/// point: it hands down a height and the child decides. The one caller today
/// is the Record screen's pinned bar, whose Save button never sheds and whose
/// courtesy note obeys rule 2 (see `_DraftAutosavesNote`).
class BudgetedColumn extends MultiChildRenderObjectWidget {
  const BudgetedColumn({super.key, required super.children, this.layoutOrder});

  /// Indices into `children`, in the order they are **served from the
  /// budget** — the first is laid out into the whole of it, each later one
  /// into what is left. Defaults to list order.
  ///
  /// It exists because **the order things are read in and the order they may
  /// be taken away in are different questions.** The Record screen's pinned
  /// bar reads note-then-button and yields button-first, because the button
  /// is the control the screen exists for and the note is a courtesy.
  /// Children are always *painted* in list order, whatever this says.
  final List<int>? layoutOrder;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderBudgetedColumn(layoutOrder: layoutOrder);

  @override
  void updateRenderObject(
      BuildContext context, RenderBudgetedColumn renderObject) {
    renderObject.layoutOrder = layoutOrder;
  }
}

class RenderBudgetedColumn extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _BudgetedParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _BudgetedParentData> {
  RenderBudgetedColumn({List<int>? layoutOrder})
      // ignore: prefer_initializing_formals
      : _layoutOrder = layoutOrder;

  List<int>? _layoutOrder;
  List<int>? get layoutOrder => _layoutOrder;
  set layoutOrder(List<int>? value) {
    if (_sameOrder(_layoutOrder, value)) return;
    _layoutOrder = value;
    markNeedsLayout();
  }

  static bool _sameOrder(List<int>? a, List<int>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _BudgetedParentData) {
      child.parentData = _BudgetedParentData();
    }
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    final budget = constraints.maxHeight;
    final children = <RenderBox>[];
    for (var c = firstChild; c != null; c = childAfter(c)) {
      children.add(c);
    }

    // A `layoutOrder` that does not name every child exactly once is a
    // silently wrong layout — the unnamed child would never be laid out at
    // all, which is the failure this whole file exists to make loud.
    final order = layoutOrder;
    assert(
      order == null ||
          (order.length == children.length &&
              order.toSet().length == children.length &&
              order.every((i) => i >= 0 && i < children.length)),
      'layoutOrder must name each of the ${children.length} children exactly '
      'once; got $order',
    );
    final serving = order != null && order.length == children.length
        ? [for (final i in order) children[i]]
        : children;

    var used = 0.0;
    for (final child in serving) {
      child.layout(
        BoxConstraints(
          minWidth: width,
          maxWidth: width,
          maxHeight: math.max(0.0, budget - used),
        ),
        parentUsesSize: true,
      );
      used += child.size.height;
    }

    // Painted top to bottom in *list* order, whatever order they were served
    // from the budget in.
    var y = 0.0;
    for (final child in children) {
      (child.parentData! as _BudgetedParentData).offset = Offset(0, y);
      y += child.size.height;
    }
    // **A child that took more than it was given is clamped here rather
    // than reported**, because a bare `RenderBox` has no overflow stripe to
    // draw. It can only happen when the budget is smaller than a child that
    // may not shed at all — the Record screen's Save button is the only such
    // child in the app — and the space-budget ladders assert that it does
    // not happen at any text size. If you add a third caller, add that
    // assertion with it.
    size = constraints.constrain(Size(width, used));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

class _BudgetedParentData extends ContainerBoxParentData<RenderBox> {}
