// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:quiver/check.dart';

import 'bindings/interpreter.dart';
import 'bindings/model.dart';
import 'bindings/types.dart';
import 'ffi/helper.dart';
import 'interpreter_options.dart';
import 'tensor.dart';

/// TensorFlowLite interpreter for running inference on a model.
class Interpreter {
  final Pointer<TfLiteInterpreter> _interpreter;
  bool _deleted = false;
  bool _allocated = false;

  Interpreter._(this._interpreter);

  /// Creates interpreter from model or throws if unsuccessful.
  factory Interpreter._Interpreter(_Model model, {InterpreterOptions options}) {
    final interpreter = TfLiteInterpreterCreate(
        model.base, options?.base ?? cast<TfLiteInterpreterOptions>(nullptr));
    checkArgument(isNotNull(interpreter),
        message: 'Unable to create interpreter.');
    return Interpreter._(interpreter);
  }

  /// Creates interpreter from a model file or throws if unsuccessful.
  factory Interpreter.fromFile(File modelFile, {InterpreterOptions options}) {
    final model = _Model.fromFile(modelFile.path);
    final interpreter = Interpreter._Interpreter(model, options: options);
    model.delete();
    return interpreter;
  }

  /// Creates interpreter from a buffer
  factory Interpreter.fromBuffer(Uint8List buffer,
      {InterpreterOptions options}) {
    final model = _Model.fromBuffer(buffer);
    final interpreter = Interpreter._Interpreter(model, options: options);
    model.delete();
    return interpreter;
  }

  /// Creates interpreter from a asset file name
  static Future<Interpreter> fromAsset(String assetName,
      {InterpreterOptions options}) async {
    Uint8List buffer;
    try {
      buffer = await _getBuffer(assetName);
    } catch (err) {
      print(
          'Caught error: $err, while trying to create interpreter from asset: $assetName');
    }
    return Interpreter.fromBuffer(buffer, options: options);
  }

  /// Get byte buffer
  static Future<Uint8List> _getBuffer(String assetFileName) async {
    ByteData rawAssetFile;
    try {
      rawAssetFile = await rootBundle.load('assets/$assetFileName');
    } catch (err) {
      print(
          'Caught error: $err, while trying to load asset from "assets/$assetFileName"');
    }
    final rawBytes = rawAssetFile.buffer.asUint8List();
    return rawBytes;
  }

  /// Destroys the model instance.
  void delete() {
    checkState(!_deleted, message: 'Interpreter already deleted.');
    TfLiteInterpreterDelete(_interpreter);
    _deleted = true;
  }

  /// Updates allocations for all tensors.
  void allocateTensors() {
    checkState(!_allocated, message: 'Interpreter already allocated.');
    checkState(
        TfLiteInterpreterAllocateTensors(_interpreter) == TfLiteStatus.ok);
    _allocated = true;
  }

  /// Runs inference for the loaded graph.
  void invoke() {
    checkState(_allocated, message: 'Interpreter not allocated.');
    checkState(TfLiteInterpreterInvoke(_interpreter) == TfLiteStatus.ok);
  }

  /// Run for single input and output
  void run(Object input, Object output) {
    runForMultipleInputs([input], {0: output});
  }

  /// Run for multiple inputs and outputs
  void runForMultipleInputs(List<Object> inputs, Map<int, Object> outputs) {
    if (inputs == null || inputs.isEmpty) {
      throw ArgumentError('Input error: Inputs should not be null or empty.');
    }
    if (outputs == null || outputs.isEmpty) {
      throw ArgumentError('Input error: Outputs should not be null or empty.');
    }

    if (!_allocated) {
      allocateTensors();
      _allocated = true;
    }

    var inputTensors = getInputTensors();
    for (var i = 0; i < inputs.length; i++) {
      inputTensors[i].setTo(inputs[i]);
    }
    invoke();
    var outputTensors = getOutputTensors();
    for (var i = 0; i < outputTensors.length; i++) {
      outputs[i] = outputTensors[i].copyTo(outputs[i]);
    }
  }

  /// Gets all input tensors associated with the model.
  List<Tensor> getInputTensors() => List.generate(
      TfLiteInterpreterGetInputTensorCount(_interpreter),
      (i) => Tensor(TfLiteInterpreterGetInputTensor(_interpreter, i)),
      growable: false);

  /// Gets all output tensors associated with the model.
  List<Tensor> getOutputTensors() => List.generate(
      TfLiteInterpreterGetOutputTensorCount(_interpreter),
      (i) => Tensor(TfLiteInterpreterGetOutputTensor(_interpreter, i)),
      growable: false);

  /// Resize input tensor for the given tensor index. `allocateTensors` must be called again afterward.
  void resizeInputTensor(int tensorIndex, List<int> shape) {
    final dimensionSize = shape.length;
    final dimensions = allocate<Int32>(count: dimensionSize);
    final externalTypedData = dimensions.asTypedList(dimensionSize);
    externalTypedData.setRange(0, dimensionSize, shape);
    final status = TfLiteInterpreterResizeInputTensor(
        _interpreter, tensorIndex, dimensions, dimensionSize);
    free(dimensions);
    checkState(status == TfLiteStatus.ok);
    _allocated = false;
  }

  /// Gets the input Tensor for the provided input index.
  Tensor getInputTensor(int index) {
    //TODO: Optimization: inputTensors in dart variable
    final tensors = getInputTensors();
    if (index < 0 || index >= tensors.length) {
      throw ArgumentError('Invalid input Tensor index: $index');
    }

    final inputTensor = tensors[index];
    return inputTensor;
  }

  /// Gets the output Tensor for the provided output index.
  Tensor getOutputTensor(int index) {
    //TODO: Optimization: outputTensors in dart variable
    final tensors = getOutputTensors();
    if (index < 0 || index >= tensors.length) {
      throw ArgumentError('Invalid output Tensor index: $index');
    }

    final outputTensor = tensors[index];
    return outputTensor;
  }

  /// Gets index of an input given the op name of the input.
  int getInputIndex(String opName) {
    final inputTensors = getInputTensors();
    var inputTensorsIndex = <String, int>{};
    for (var i = 0; i < inputTensors.length; i++) {
      inputTensorsIndex[inputTensors[i].name] = i;
    }
    if (inputTensorsIndex.containsKey(opName)) {
      return inputTensorsIndex[opName];
    } else {
      throw ArgumentError(
          "Input error: $opName' is not a valid name for any input. Names of inputs and their indexes are $inputTensorsIndex");
    }
  }

  /// Gets index of an output given the op name of the output.
  int getOutputIndex(String opName) {
    final outputTensors = getOutputTensors();
    var outputTensorsIndex = <String, int>{};
    for (var i = 0; i < outputTensors.length; i++) {
      outputTensorsIndex[outputTensors[i].name] = i;
    }
    if (outputTensorsIndex.containsKey(opName)) {
      return outputTensorsIndex[opName];
    } else {
      throw ArgumentError(
          "Output error: $opName' is not a valid name for any output. Names of outputs and their indexes are $outputTensorsIndex");
    }
  }

  //TODO: (JAVA) Add long getLastNativeInferenceDurationNanoseconds()
  //TODO: (JAVA) void modifyGraphWithDelegate(Delegate delegate)
  //TODO: (JAVA) void resetVariableTensors()

}

/// TensorFlowLite model.
class _Model {
  final Pointer<TfLiteModel> _model;
  bool _deleted = false;

  Pointer<TfLiteModel> get base => _model;

  _Model._(this._model);

  /// Loads model from a file or throws if unsuccessful.
  factory _Model.fromFile(String path) {
    final cpath = Utf8.toUtf8(path);
    final model = TfLiteModelCreateFromFile(cpath);
    free(cpath);
    checkArgument(isNotNull(model),
        message: 'Unable to create model from file');
    return _Model._(model);
  }

  /// Loads model from a buffer or throws if unsuccessful.
  factory _Model.fromBuffer(Uint8List buffer) {
    final size = buffer.length;
    final ptr = allocate<Uint8>(count: size);
    final externalTypedData = ptr.asTypedList(size);
    externalTypedData.setRange(0, buffer.length, buffer);
    final model = TfLiteModelCreateFromBuffer(ptr.cast(), buffer.length);
    checkArgument(isNotNull(model),
        message: 'Unable to create model from buffer');
    return _Model._(model);
  }

  /// Destroys the model instance.
  void delete() {
    checkState(!_deleted, message: 'Model already deleted.');
    TfLiteModelDelete(_model);
    _deleted = true;
  }
}
