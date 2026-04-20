class Label {
  final String name;
  int? _offset;

  Label(this.name);

  int get offset {
    if (_offset == null) throw StateError('Label "$name" not yet resolved');
    return _offset!;
  }

  bool get isResolved => _offset != null;

  void resolve(int offset) {
    _offset = offset;
  }

  @override
  String toString() => '$name:';
}
