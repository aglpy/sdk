// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:_fe_analyzer_shared/src/macros/api.dart' as macro;
import 'package:_fe_analyzer_shared/src/macros/executor.dart' as macro;
import 'package:_fe_analyzer_shared/src/macros/executor/span.dart' as macro;
import 'package:_fe_analyzer_shared/src/macros/uri.dart';
import 'package:_fe_analyzer_shared/src/scanner/scanner.dart';
import 'package:front_end/src/fasta/uri_offset.dart';
import 'package:kernel/ast.dart';
import 'package:kernel/class_hierarchy.dart';

import '../../../api_prototype/compiler_options.dart';
import '../../../base/common.dart';
import '../../builder/builder.dart';
import '../../builder/declaration_builders.dart';
import '../../builder/member_builder.dart';
import '../../builder/prefix_builder.dart';
import '../../builder/type_builder.dart';
import '../../codes/fasta_codes.dart';
import '../../source/source_class_builder.dart';
import '../../source/source_constructor_builder.dart';
import '../../source/source_extension_builder.dart';
import '../../source/source_extension_type_declaration_builder.dart';
import '../../source/source_factory_builder.dart';
import '../../source/source_field_builder.dart';
import '../../source/source_library_builder.dart';
import '../../source/source_loader.dart';
import '../../source/source_procedure_builder.dart';
import '../../source/source_type_alias_builder.dart';
import '../benchmarker.dart' show BenchmarkSubdivides, Benchmarker;
import '../hierarchy/hierarchy_builder.dart';
import 'annotation_parser.dart';
import 'introspectors.dart';
import 'offsets.dart';

const String intermediateAugmentationScheme = 'org-dartlang-augmentation';

final Uri macroLibraryUri =
    Uri.parse('package:_fe_analyzer_shared/src/macros/api.dart');
const String macroClassName = 'Macro';

class MacroDeclarationData {
  bool macrosAreAvailable = false;
  Map<Uri, List<String>> macroDeclarations = {};
  List<List<Uri>>? compilationSequence;
  List<Map<Uri, Map<String, List<String>>>> neededPrecompilations = [];
}

class MacroApplication {
  final UriOffset uriOffset;
  final ClassBuilder classBuilder;
  final String constructorName;
  final macro.Arguments arguments;
  final bool isErroneous;
  final String? unhandledReason;

  /// Creates a [MacroApplication] for a macro annotation that should be
  /// applied.
  MacroApplication(this.classBuilder, this.constructorName, this.arguments,
      {required this.uriOffset})
      : isErroneous = false,
        unhandledReason = null;

  /// Creates an erroneous [MacroApplication] for a macro annotation using
  /// syntax that is not unhandled.
  // TODO(johnniwinther): Separate this into unhandled (but valid) and
  //  unsupported (thus invalid) annotations.
  MacroApplication.unhandled(String this.unhandledReason, this.classBuilder,
      {required this.uriOffset})
      : isErroneous = true,
        constructorName = '',
        arguments = new macro.Arguments(const [], const {});

  /// Creates an erroneous [MacroApplication] for an invalid macro application
  /// for which an error has been reported, which should _not_ be applied. For
  /// instance a macro annotation of a macro declared in the same library cycle.
  MacroApplication.invalid(this.classBuilder, {required this.uriOffset})
      : constructorName = '',
        isErroneous = true,
        unhandledReason = null,
        arguments = new macro.Arguments(const [], const {});

  bool get isUnhandled => unhandledReason != null;

  late macro.MacroInstanceIdentifier instanceIdentifier;
  late Set<macro.Phase> phasesToExecute;

  @override
  String toString() {
    StringBuffer sb = new StringBuffer();
    sb.write(classBuilder.name);
    sb.write('.');
    if (constructorName.isEmpty) {
      sb.write('new');
    } else {
      sb.write(constructorName);
    }
    sb.write('(');
    String comma = '';
    for (Object? positional in arguments.positional) {
      sb.write(comma);
      sb.write(positional);
      comma = ',';
    }
    for (MapEntry<String, Object?> named in arguments.named.entries) {
      sb.write(comma);
      sb.write(named.key);
      sb.write(':');
      sb.write(named.value);
      comma = ',';
    }
    sb.write(')');
    return sb.toString();
  }
}

class MacroApplicationDataForTesting {
  Map<SourceLibraryBuilder, LibraryMacroApplicationData> libraryData = {};
  Map<SourceLibraryBuilder, String> libraryTypesResult = {};
  Map<SourceLibraryBuilder, String> libraryDefinitionResult = {};

  Map<SourceLibraryBuilder, MacroExecutionResultsForTesting> libraryResults =
      {};
  Map<SourceClassBuilder, MacroExecutionResultsForTesting> classResults = {};
  Map<MemberBuilder, MacroExecutionResultsForTesting> memberResults = {};

  List<ApplicationDataForTesting> typesApplicationOrder = [];
  List<ApplicationDataForTesting> declarationsApplicationOrder = [];
  List<ApplicationDataForTesting> definitionApplicationOrder = [];

  MacroExecutionResultsForTesting _getResultsForTesting(Builder builder) {
    MacroExecutionResultsForTesting resultsForTesting;
    if (builder is SourceLibraryBuilder) {
      resultsForTesting =
          libraryResults[builder] ??= new MacroExecutionResultsForTesting();
    } else if (builder is SourceClassBuilder) {
      resultsForTesting =
          classResults[builder] ??= new MacroExecutionResultsForTesting();
    } else {
      resultsForTesting = memberResults[builder as MemberBuilder] ??=
          new MacroExecutionResultsForTesting();
    }
    return resultsForTesting;
  }

  void registerTypesResults(
      Builder builder, List<macro.MacroExecutionResult> results) {
    _getResultsForTesting(builder).typesResults.addAll(results);
  }

  void registerDeclarationsResult(
      Builder builder, macro.MacroExecutionResult result, String source) {
    MacroExecutionResultsForTesting resultsForTesting =
        _getResultsForTesting(builder);
    resultsForTesting.declarationsResults.add(result);
    resultsForTesting.declarationsSources.add(source);
  }

  void registerDeclarationsResults(
      Builder builder, List<macro.MacroExecutionResult> results) {
    MacroExecutionResultsForTesting resultsForTesting =
        _getResultsForTesting(builder);
    resultsForTesting.declarationsResults.addAll(results);
  }

  void registerDefinitionsResults(
      Builder builder, List<macro.MacroExecutionResult> results) {
    _getResultsForTesting(builder).definitionsResults.addAll(results);
  }
}

class MacroExecutionResultsForTesting {
  List<macro.MacroExecutionResult> typesResults = [];
  List<macro.MacroExecutionResult> declarationsResults = [];
  List<String> declarationsSources = [];
  List<macro.MacroExecutionResult> definitionsResults = [];
}

class ApplicationDataForTesting {
  final ApplicationData applicationData;
  final MacroApplication macroApplication;

  ApplicationDataForTesting(this.applicationData, this.macroApplication);

  @override
  String toString() {
    StringBuffer sb = new StringBuffer();
    sb.write(applicationData.textForTesting);
    sb.write(':');
    sb.write(macroApplication);
    return sb.toString();
  }
}

class LibraryMacroApplicationData {
  ApplicationData? libraryApplications;
  Map<SourceClassBuilder, ClassMacroApplicationData> classData = {};
  Map<MemberBuilder, ApplicationData> memberApplications = {};
}

class ClassMacroApplicationData {
  ApplicationData? classApplications;
  Map<MemberBuilder, ApplicationData> memberApplications = {};
}

/// Macro classes that need to be precompiled.
class NeededPrecompilations {
  /// Map from library uris to macro class names and the names of constructor
  /// their constructors is returned for macro classes that need to be
  /// precompiled.
  final Map<Uri, Map<String, List<String>>> macroDeclarations;

  NeededPrecompilations(this.macroDeclarations);
}

void checkMacroApplications(
    ClassHierarchy hierarchy,
    Class macroClass,
    List<SourceLibraryBuilder> sourceLibraryBuilders,
    MacroApplications? macroApplications) {
  Map<Library, List<LibraryMacroApplicationData>> libraryData = {};
  if (macroApplications != null) {
    for (MapEntry<SourceLibraryBuilder, LibraryMacroApplicationData> entry
        in macroApplications._libraryData.entries) {
      (libraryData[entry.key.library] ??= []).add(entry.value);
    }
  }
  for (SourceLibraryBuilder libraryBuilder in sourceLibraryBuilders) {
    void checkAnnotations(List<Expression> annotations,
        List<ApplicationData>? applicationDataList,
        {required Uri fileUri}) {
      if (annotations.isEmpty) {
        return;
      }
      // We cannot currently identify macro applications by offsets because
      // file offsets on annotations are not stable.
      // TODO(johnniwinther): Handle file uri + offset on annotations.
      Map<Class, Map<int, MacroApplication>> macroApplications = {};
      if (applicationDataList != null) {
        for (ApplicationData applicationData in applicationDataList) {
          for (MacroApplication application
              in applicationData.macroApplications) {
            Map<int, MacroApplication> applications =
                macroApplications[application.classBuilder.cls] ??= {};
            int fileOffset = application.uriOffset.fileOffset;
            assert(
                !applications.containsKey(fileOffset),
                "Multiple annotations at offset $fileOffset: "
                "${applications[fileOffset]} and ${application}.");
            applications[fileOffset] = application;
          }
        }
      }
      for (Expression annotation in annotations) {
        if (annotation is ConstantExpression) {
          Constant constant = annotation.constant;
          if (constant is InstanceConstant &&
              hierarchy.isSubInterfaceOf(constant.classNode, macroClass)) {
            Map<int, MacroApplication>? applications =
                macroApplications[constant.classNode];
            MacroApplication? macroApplication =
                applications?.remove(annotation.fileOffset);
            if (macroApplication != null) {
              if (macroApplication.isUnhandled) {
                libraryBuilder.addProblem(
                    templateUnhandledMacroApplication
                        .withArguments(macroApplication.unhandledReason!),
                    annotation.fileOffset,
                    noLength,
                    fileUri);
              }
            } else {
              // TODO(johnniwinther): Improve the diagnostics about why the
              // macro didn't apply here.
              libraryBuilder.addProblem(messageUnsupportedMacroApplication,
                  annotation.fileOffset, noLength, fileUri);
            }
          }
        }
      }
    }

    void checkMembers(Iterable<Member> members,
        Map<Annotatable, List<ApplicationData>> memberData) {
      for (Member member in members) {
        checkAnnotations(member.annotations, memberData[member],
            fileUri: member.fileUri);
      }
    }

    Map<Class, List<ClassMacroApplicationData>> classData = {};
    Map<Annotatable, List<ApplicationData>> libraryMemberData = {};
    List<LibraryMacroApplicationData>? libraryMacroApplicationDataList =
        libraryData[libraryBuilder.library];
    if (libraryMacroApplicationDataList != null) {
      for (LibraryMacroApplicationData libraryMacroApplicationData
          in libraryMacroApplicationDataList) {
        for (MapEntry<SourceClassBuilder, ClassMacroApplicationData> entry
            in libraryMacroApplicationData.classData.entries) {
          (classData[entry.key.cls] ??= []).add(entry.value);
        }
        for (MapEntry<MemberBuilder, ApplicationData> entry
            in libraryMacroApplicationData.memberApplications.entries) {
          for (Annotatable annotatable in entry.key.annotatables) {
            (libraryMemberData[annotatable] ??= []).add(entry.value);
          }
        }
      }
    }

    Library library = libraryBuilder.library;
    checkMembers(library.members, libraryMemberData);
    for (Class cls in library.classes) {
      List<ClassMacroApplicationData>? classMacroApplications = classData[cls];
      List<ApplicationData> applicationDataList = [];
      if (classMacroApplications != null) {
        for (ClassMacroApplicationData classMacroApplicationData
            in classMacroApplications) {
          ApplicationData? classApplications =
              classMacroApplicationData.classApplications;
          if (classApplications != null) {
            applicationDataList.add(classApplications);
          }
        }
      }
      checkAnnotations(cls.annotations, applicationDataList,
          fileUri: cls.fileUri);

      Map<Annotatable, List<ApplicationData>> classMemberData = {};
      if (classMacroApplications != null) {
        for (ClassMacroApplicationData classMacroApplicationData
            in classMacroApplications) {
          for (MapEntry<MemberBuilder, ApplicationData> entry
              in classMacroApplicationData.memberApplications.entries) {
            for (Annotatable annotatable in entry.key.annotatables) {
              (classMemberData[annotatable] ??= []).add(entry.value);
            }
          }
        }
      }
      checkMembers(cls.members, classMemberData);
    }
  }
}

class MacroApplications {
  final SourceLoader _sourceLoader;
  final macro.MacroExecutor _macroExecutor;
  final MacroIntrospection _macroIntrospection;
  final Map<SourceLibraryBuilder, LibraryMacroApplicationData> _libraryData =
      {};
  final Map<SourceLibraryBuilder, List<macro.MacroExecutionResult>>
      _libraryResults = {};
  final Map<SourceLibraryBuilder, Map<Uri, List<macro.Span>>>
      _libraryResultSpans = {};
  final MacroApplicationDataForTesting? dataForTesting;

  List<LibraryMacroApplicationData> _pendingLibraryData = [];

  MacroApplications(
      this._sourceLoader, this._macroExecutor, this.dataForTesting)
      : _macroIntrospection = new MacroIntrospection(_sourceLoader);

  macro.MacroExecutor get macroExecutor => _macroExecutor;

  bool get hasLoadableMacroIds => _pendingLibraryData.isNotEmpty;

  void computeLibrariesMacroApplicationData(
      Iterable<SourceLibraryBuilder> libraryBuilders,
      Set<ClassBuilder> currentMacroDeclarations) {
    for (SourceLibraryBuilder libraryBuilder in libraryBuilders) {
      _computeSourceLibraryMacroApplicationData(
          libraryBuilder, currentMacroDeclarations);
    }
  }

  void _computeSourceLibraryMacroApplicationData(
      SourceLibraryBuilder libraryBuilder,
      Set<ClassBuilder> currentMacroDeclarations) {
    // TODO(johnniwinther): Handle augmentation libraries.
    LibraryMacroApplicationData libraryMacroApplicationData =
        new LibraryMacroApplicationData();

    List<MacroApplication>? libraryMacroApplications = prebuildAnnotations(
        enclosingLibrary: libraryBuilder,
        scope: libraryBuilder.scope,
        fileUri: libraryBuilder.fileUri,
        metadataBuilders: libraryBuilder.metadata,
        currentMacroDeclarations: currentMacroDeclarations);
    if (libraryMacroApplications != null) {
      libraryMacroApplicationData.libraryApplications =
          new LibraryApplicationData(
              _macroIntrospection, libraryBuilder, libraryMacroApplications);
    }

    Iterator<Builder> iterator = libraryBuilder.localMembersIterator;
    while (iterator.moveNext()) {
      Builder builder = iterator.current;
      if (builder is SourceClassBuilder) {
        SourceClassBuilder classBuilder = builder;
        ClassMacroApplicationData classMacroApplicationData =
            new ClassMacroApplicationData();
        List<MacroApplication>? classMacroApplications = prebuildAnnotations(
            enclosingLibrary: libraryBuilder,
            scope: classBuilder.scope,
            fileUri: classBuilder.fileUri,
            metadataBuilders: classBuilder.metadata,
            currentMacroDeclarations: currentMacroDeclarations);
        if (classMacroApplications != null) {
          classMacroApplicationData.classApplications =
              new ClassApplicationData(_macroIntrospection, libraryBuilder,
                  classBuilder, classMacroApplications);
        }
        Iterator<Builder> memberIterator = classBuilder.localMemberIterator();
        while (memberIterator.moveNext()) {
          Builder memberBuilder = memberIterator.current;
          if (memberBuilder is SourceProcedureBuilder) {
            List<MacroApplication>? macroApplications = prebuildAnnotations(
                enclosingLibrary: libraryBuilder,
                scope: classBuilder.scope,
                fileUri: memberBuilder.fileUri,
                metadataBuilders: memberBuilder.metadata,
                currentMacroDeclarations: currentMacroDeclarations);
            if (macroApplications != null) {
              classMacroApplicationData.memberApplications[memberBuilder] =
                  new MemberApplicationData(_macroIntrospection, libraryBuilder,
                      memberBuilder, macroApplications);
            }
          } else if (memberBuilder is SourceFieldBuilder) {
            List<MacroApplication>? macroApplications = prebuildAnnotations(
                enclosingLibrary: libraryBuilder,
                scope: classBuilder.scope,
                fileUri: memberBuilder.fileUri,
                metadataBuilders: memberBuilder.metadata,
                currentMacroDeclarations: currentMacroDeclarations);
            if (macroApplications != null) {
              classMacroApplicationData.memberApplications[memberBuilder] =
                  new MemberApplicationData(_macroIntrospection, libraryBuilder,
                      memberBuilder, macroApplications);
            }
          } else {
            throw new UnsupportedError("Unexpected class member "
                "$memberBuilder (${memberBuilder.runtimeType})");
          }
        }
        Iterator<MemberBuilder> constructorIterator =
            classBuilder.localConstructorIterator();
        while (constructorIterator.moveNext()) {
          MemberBuilder memberBuilder = constructorIterator.current;
          if (memberBuilder is DeclaredSourceConstructorBuilder) {
            List<MacroApplication>? macroApplications = prebuildAnnotations(
                enclosingLibrary: libraryBuilder,
                scope: classBuilder.scope,
                fileUri: memberBuilder.fileUri,
                metadataBuilders: memberBuilder.metadata,
                currentMacroDeclarations: currentMacroDeclarations);
            if (macroApplications != null) {
              classMacroApplicationData.memberApplications[memberBuilder] =
                  new MemberApplicationData(_macroIntrospection, libraryBuilder,
                      memberBuilder, macroApplications);
            }
          } else if (memberBuilder is SourceFactoryBuilder) {
            List<MacroApplication>? macroApplications = prebuildAnnotations(
                enclosingLibrary: libraryBuilder,
                scope: classBuilder.scope,
                fileUri: memberBuilder.fileUri,
                metadataBuilders: memberBuilder.metadata,
                currentMacroDeclarations: currentMacroDeclarations);
            if (macroApplications != null) {
              classMacroApplicationData.memberApplications[memberBuilder] =
                  new MemberApplicationData(_macroIntrospection, libraryBuilder,
                      memberBuilder, macroApplications);
            }
          } else {
            throw new UnsupportedError("Unexpected constructor "
                "$memberBuilder (${memberBuilder.runtimeType})");
          }
        }

        if (classMacroApplicationData.classApplications != null ||
            classMacroApplicationData.memberApplications.isNotEmpty) {
          libraryMacroApplicationData.classData[builder] =
              classMacroApplicationData;
        }
      } else if (builder is SourceProcedureBuilder) {
        List<MacroApplication>? macroApplications = prebuildAnnotations(
            enclosingLibrary: libraryBuilder,
            scope: libraryBuilder.scope,
            fileUri: builder.fileUri,
            metadataBuilders: builder.metadata,
            currentMacroDeclarations: currentMacroDeclarations);
        if (macroApplications != null) {
          libraryMacroApplicationData.memberApplications[builder] =
              new MemberApplicationData(_macroIntrospection, libraryBuilder,
                  builder, macroApplications);
        }
      } else if (builder is SourceFieldBuilder) {
        List<MacroApplication>? macroApplications = prebuildAnnotations(
            enclosingLibrary: libraryBuilder,
            scope: libraryBuilder.scope,
            fileUri: builder.fileUri,
            metadataBuilders: builder.metadata,
            currentMacroDeclarations: currentMacroDeclarations);
        if (macroApplications != null) {
          libraryMacroApplicationData.memberApplications[builder] =
              new MemberApplicationData(_macroIntrospection, libraryBuilder,
                  builder, macroApplications);
        }
      } else if (builder is SourceExtensionBuilder ||
          builder is SourceExtensionTypeDeclarationBuilder ||
          builder is SourceTypeAliasBuilder) {
        // TODO(johnniwinther): Support macro applications.
      } else if (builder is PrefixBuilder) {
        // Macro applications are not supported.
      } else {
        throw new UnsupportedError("Unexpected library member "
            "$builder (${builder.runtimeType})");
      }
    }
    if (libraryMacroApplications != null ||
        libraryMacroApplicationData.classData.isNotEmpty ||
        libraryMacroApplicationData.memberApplications.isNotEmpty) {
      _libraryData[libraryBuilder] = libraryMacroApplicationData;
      dataForTesting?.libraryData[libraryBuilder] = libraryMacroApplicationData;
      _pendingLibraryData.add(libraryMacroApplicationData);
    }
  }

  Future<void> loadMacroIds(Benchmarker? benchmarker) async {
    Map<MacroApplication, macro.MacroInstanceIdentifier> instanceIdCache = {};

    Future<void> ensureMacroClassIds(ApplicationData? applicationData) async {
      if (applicationData == null) {
        return;
      }
      macro.DeclarationKind targetDeclarationKind =
          applicationData.declarationKind;
      List<MacroApplication>? applications = applicationData.macroApplications;
      for (MacroApplication application in applications) {
        if (application.isErroneous) {
          application.phasesToExecute = {};
          continue;
        }
        Uri libraryUri = application.classBuilder.libraryBuilder.importUri;
        String macroClassName = application.classBuilder.name;
        try {
          benchmarker?.beginSubdivide(
              BenchmarkSubdivides.macroApplications_macroExecutorLoadMacro);
          benchmarker?.endSubdivide();
          try {
            benchmarker?.beginSubdivide(BenchmarkSubdivides
                .macroApplications_macroExecutorInstantiateMacro);
            macro.MacroInstanceIdentifier instance =
                application.instanceIdentifier = instanceIdCache[
                        application] ??=
                    // TODO: Dispose of these instances using
                    // `macroExecutor.disposeMacro` once we are done with them.
                    await macroExecutor.instantiateMacro(
                        libraryUri,
                        macroClassName,
                        application.constructorName,
                        application.arguments);

            application.phasesToExecute = macro.Phase.values.where((phase) {
              return instance.shouldExecute(targetDeclarationKind, phase);
            }).toSet();

            if (!instance.supportsDeclarationKind(targetDeclarationKind)) {
              Iterable<macro.DeclarationKind> supportedKinds = macro
                  .DeclarationKind.values
                  .where(instance.supportsDeclarationKind);
              if (supportedKinds.isEmpty) {
                // TODO(johnniwinther): Improve messaging here. Is it an error
                //  for a macro class to _not_ implement at least one of the
                //  macro interfaces?
                applicationData.libraryBuilder.addProblem(
                    messageNoMacroApplicationTarget,
                    application.uriOffset.fileOffset,
                    noLength,
                    application.uriOffset.uri);
              } else {
                applicationData.libraryBuilder.addProblem(
                    templateInvalidMacroApplicationTarget.withArguments(
                        DeclarationKindHelper.joinWithOr(supportedKinds)),
                    application.uriOffset.fileOffset,
                    noLength,
                    application.uriOffset.uri);
              }
            }
            benchmarker?.endSubdivide();
          } catch (e, s) {
            throw "Error instantiating macro `${application}`: "
                "$e\n$s";
          }
        } catch (e, s) {
          throw "Error loading macro class "
              "'${application.classBuilder.name}' from "
              "'${application.classBuilder.libraryBuilder.importUri}': "
              "$e\n$s";
        }
      }
    }

    for (LibraryMacroApplicationData libraryData in _pendingLibraryData) {
      await ensureMacroClassIds(libraryData.libraryApplications);
      for (ClassMacroApplicationData classData
          in libraryData.classData.values) {
        await ensureMacroClassIds(classData.classApplications);
        for (ApplicationData applicationData
            in classData.memberApplications.values) {
          await ensureMacroClassIds(applicationData);
        }
      }
      for (ApplicationData applicationData
          in libraryData.memberApplications.values) {
        await ensureMacroClassIds(applicationData);
      }
    }
    _pendingLibraryData.clear();
  }

  Future<List<macro.MacroExecutionResult>> _applyTypeMacros(
      SourceLibraryBuilder originLibraryBuilder,
      ApplicationData applicationData) async {
    macro.MacroTarget macroTarget = applicationData.macroTarget;
    List<macro.MacroExecutionResult> results = [];
    for (MacroApplication macroApplication
        in applicationData.macroApplications) {
      if (!macroApplication.phasesToExecute.remove(macro.Phase.types)) {
        continue;
      }
      if (retainDataForTesting) {
        dataForTesting!.typesApplicationOrder.add(
            new ApplicationDataForTesting(applicationData, macroApplication));
      }
      macro.MacroExecutionResult result =
          await _macroExecutor.executeTypesPhase(
              macroApplication.instanceIdentifier,
              macroTarget,
              _macroIntrospection.typePhaseIntrospector);
      result.reportDiagnostics(
          _macroIntrospection, macroApplication, applicationData);
      if (result.isNotEmpty) {
        _registerMacroExecutionResult(originLibraryBuilder, result);
        results.add(result);
      }
    }

    if (retainDataForTesting) {
      dataForTesting?.registerTypesResults(applicationData.builder, results);
    }
    return results;
  }

  void enterTypeMacroPhase() {
    _macroIntrospection.enterTypeMacroPhase();
  }

  Future<List<SourceLibraryBuilder>> applyTypeMacros() async {
    // TODO(johnniwinther): Maintain a pending list instead of running through
    // all annotations to find the once have to be applied now.
    List<SourceLibraryBuilder> augmentationLibraries = [];
    for (MapEntry<SourceLibraryBuilder, LibraryMacroApplicationData> entry
        in _libraryData.entries) {
      List<macro.MacroExecutionResult> executionResults = [];
      SourceLibraryBuilder libraryBuilder = entry.key;
      LibraryMacroApplicationData data = entry.value;

      ApplicationData? libraryData = data.libraryApplications;
      if (libraryData != null) {
        executionResults
            .addAll(await _applyTypeMacros(libraryBuilder.origin, libraryData));
      }
      for (ApplicationData applicationData in data.memberApplications.values) {
        executionResults.addAll(
            await _applyTypeMacros(libraryBuilder.origin, applicationData));
      }
      for (MapEntry<ClassBuilder, ClassMacroApplicationData> entry
          in data.classData.entries) {
        ClassMacroApplicationData classApplicationData = entry.value;
        for (ApplicationData applicationData
            in classApplicationData.memberApplications.values) {
          executionResults.addAll(
              await _applyTypeMacros(libraryBuilder.origin, applicationData));
        }
        if (classApplicationData.classApplications != null) {
          executionResults.addAll(await _applyTypeMacros(
              libraryBuilder.origin, classApplicationData.classApplications!));
        }
      }
      if (executionResults.isNotEmpty) {
        Map<macro.OmittedTypeAnnotation, String> omittedTypes = {};
        List<macro.Span> spans = [];
        String result = _macroExecutor.buildAugmentationLibrary(
            libraryBuilder.importUri,
            executionResults,
            _macroIntrospection.resolveDeclaration,
            _macroIntrospection.resolveIdentifier,
            _macroIntrospection.types.inferOmittedType,
            omittedTypes: omittedTypes,
            spans: spans);
        assert(
            result.trim().isNotEmpty,
            "Empty types phase augmentation library source for "
            "$libraryBuilder}");
        if (result.isNotEmpty) {
          if (retainDataForTesting) {
            dataForTesting?.libraryTypesResult[libraryBuilder] = result;
          }
          Map<String, OmittedTypeBuilder>? omittedTypeBuilders =
              _macroIntrospection.types
                  .computeOmittedTypeBuilders(omittedTypes);
          SourceLibraryBuilder augmentationLibrary = await libraryBuilder.origin
              .createAugmentationLibrary(result,
                  omittedTypes: omittedTypeBuilders);
          augmentationLibraries.add(augmentationLibrary);
          _registerMacroExecutionResultSpan(
              libraryBuilder.origin, augmentationLibrary.importUri, spans);
        }
      }
    }

    return augmentationLibraries;
  }

  void _registerMacroExecutionResult(SourceLibraryBuilder originLibraryBuilder,
      macro.MacroExecutionResult result) {
    (_libraryResults[originLibraryBuilder] ??= []).add(result);
  }

  void _registerMacroExecutionResultSpan(
      SourceLibraryBuilder originLibraryBuilder,
      Uri uri,
      List<macro.Span> spans) {
    (_libraryResultSpans[originLibraryBuilder] ??= {})[uri] = spans;
  }

  Future<void> _applyDeclarationsMacros(
      SourceLibraryBuilder originLibraryBuilder,
      ApplicationData applicationData,
      Future<void> Function(SourceLibraryBuilder) onAugmentationLibrary) async {
    List<macro.MacroExecutionResult> results = [];
    macro.MacroTarget macroTarget = applicationData.macroTarget;
    for (MacroApplication macroApplication
        in applicationData.macroApplications) {
      if (!macroApplication.phasesToExecute.remove(macro.Phase.declarations)) {
        continue;
      }
      if (retainDataForTesting) {
        dataForTesting!.declarationsApplicationOrder.add(
            new ApplicationDataForTesting(applicationData, macroApplication));
      }
      macro.MacroExecutionResult result =
          await _macroExecutor.executeDeclarationsPhase(
              macroApplication.instanceIdentifier,
              macroTarget,
              _macroIntrospection.declarationPhaseIntrospector);
      result.reportDiagnostics(
          _macroIntrospection, macroApplication, applicationData);
      if (result.isNotEmpty) {
        Map<macro.OmittedTypeAnnotation, String> omittedTypes = {};
        List<macro.Span> spans = [];
        String source = _macroExecutor.buildAugmentationLibrary(
            originLibraryBuilder.importUri,
            [result],
            _macroIntrospection.resolveDeclaration,
            _macroIntrospection.resolveIdentifier,
            _macroIntrospection.types.inferOmittedType,
            omittedTypes: omittedTypes,
            spans: spans);
        if (retainDataForTesting) {
          dataForTesting?.registerDeclarationsResult(
              applicationData.builder, result, source);
        }
        _registerMacroExecutionResult(originLibraryBuilder, result);
        Map<String, OmittedTypeBuilder>? omittedTypeBuilders =
            _macroIntrospection.types.computeOmittedTypeBuilders(omittedTypes);

        SourceLibraryBuilder augmentationLibrary = await applicationData
            .libraryBuilder.origin
            .createAugmentationLibrary(source,
                omittedTypes: omittedTypeBuilders);
        _registerMacroExecutionResultSpan(
            originLibraryBuilder, augmentationLibrary.importUri, spans);
        await onAugmentationLibrary(augmentationLibrary);
        if (retainDataForTesting) {
          results.add(result);
        }
      }
    }
    if (retainDataForTesting) {
      Builder builder = applicationData.builder;
      dataForTesting?.registerDeclarationsResults(builder, results);
    }
  }

  void enterDeclarationsMacroPhase(ClassHierarchyBuilder classHierarchy) {
    _macroIntrospection.enterDeclarationsMacroPhase(classHierarchy);
  }

  Future<void> applyDeclarationsMacros(
      List<SourceClassBuilder> sortedSourceClassBuilders,
      Future<void> Function(SourceLibraryBuilder) onAugmentationLibrary) async {
    // TODO(johnniwinther): Maintain a pending list instead of running through
    // all annotations to find the once have to be applied now.
    Future<void> applyClassMacros(SourceClassBuilder classBuilder) async {
      SourceLibraryBuilder libraryBuilder = classBuilder.libraryBuilder;
      LibraryMacroApplicationData? libraryApplicationData =
          _libraryData[libraryBuilder];
      if (libraryApplicationData == null) return;

      ClassMacroApplicationData? classApplicationData =
          libraryApplicationData.classData[classBuilder];
      if (classApplicationData == null) return;
      for (ApplicationData applicationData
          in classApplicationData.memberApplications.values) {
        await _applyDeclarationsMacros(
            libraryBuilder.origin, applicationData, onAugmentationLibrary);
      }
      if (classApplicationData.classApplications != null) {
        await _applyDeclarationsMacros(libraryBuilder.origin,
            classApplicationData.classApplications!, onAugmentationLibrary);
      }
    }

    // Apply macros to classes first, in class hierarchy order.
    for (SourceClassBuilder classBuilder in sortedSourceClassBuilders) {
      await applyClassMacros(classBuilder);
      // TODO(johnniwinther): Avoid accessing augmentations from the outside.
      List<SourceClassBuilder>? augmentationClassBuilders =
          classBuilder.augmentationsForTesting;
      if (augmentationClassBuilders != null) {
        for (SourceClassBuilder augmentationClassBuilder
            in augmentationClassBuilders) {
          await applyClassMacros(augmentationClassBuilder);
        }
      }
    }

    // Apply macros to library members second.
    for (MapEntry<SourceLibraryBuilder, LibraryMacroApplicationData> entry
        in _libraryData.entries) {
      SourceLibraryBuilder libraryBuilder = entry.key;
      LibraryMacroApplicationData data = entry.value;

      ApplicationData? libraryData = data.libraryApplications;
      if (libraryData != null) {
        await _applyDeclarationsMacros(
            libraryBuilder.origin, libraryData, onAugmentationLibrary);
      }

      for (ApplicationData applicationData in data.memberApplications.values) {
        await _applyDeclarationsMacros(
            libraryBuilder.origin, applicationData, onAugmentationLibrary);
      }
    }
  }

  Future<List<macro.MacroExecutionResult>> _applyDefinitionMacros(
      SourceLibraryBuilder originLibraryBuilder,
      ApplicationData applicationData) async {
    List<macro.MacroExecutionResult> results = [];
    macro.MacroTarget macroTarget = applicationData.macroTarget;
    for (MacroApplication macroApplication
        in applicationData.macroApplications) {
      if (!macroApplication.phasesToExecute.remove(macro.Phase.definitions)) {
        continue;
      }
      if (retainDataForTesting) {
        dataForTesting!.definitionApplicationOrder.add(
            new ApplicationDataForTesting(applicationData, macroApplication));
      }
      macro.MacroExecutionResult result =
          await _macroExecutor.executeDefinitionsPhase(
              macroApplication.instanceIdentifier,
              macroTarget,
              _macroIntrospection.definitionPhaseIntrospector);
      result.reportDiagnostics(
          _macroIntrospection, macroApplication, applicationData);
      if (result.isNotEmpty) {
        _registerMacroExecutionResult(originLibraryBuilder, result);
        results.add(result);
      }
    }
    if (retainDataForTesting) {
      dataForTesting?.registerDefinitionsResults(
          applicationData.builder, results);
    }
    return results;
  }

  void enterDefinitionMacroPhase() {
    _macroIntrospection.enterDefinitionMacroPhase();
  }

  Future<List<SourceLibraryBuilder>> applyDefinitionMacros() async {
    // TODO(johnniwinther): Maintain a pending list instead of running through
    // all annotations to find the once have to be applied now.
    List<SourceLibraryBuilder> augmentationLibraries = [];
    for (MapEntry<SourceLibraryBuilder, LibraryMacroApplicationData> entry
        in _libraryData.entries) {
      List<macro.MacroExecutionResult> executionResults = [];
      SourceLibraryBuilder libraryBuilder = entry.key;
      LibraryMacroApplicationData data = entry.value;

      ApplicationData? libraryData = data.libraryApplications;
      if (libraryData != null) {
        executionResults.addAll(
            await _applyDefinitionMacros(libraryBuilder.origin, libraryData));
      }
      for (ApplicationData applicationData in data.memberApplications.values) {
        executionResults.addAll(await _applyDefinitionMacros(
            libraryBuilder.origin, applicationData));
      }
      for (MapEntry<ClassBuilder, ClassMacroApplicationData> entry
          in data.classData.entries) {
        ClassMacroApplicationData classApplicationData = entry.value;
        for (ApplicationData applicationData
            in classApplicationData.memberApplications.values) {
          executionResults.addAll(await _applyDefinitionMacros(
              libraryBuilder.origin, applicationData));
        }
        if (classApplicationData.classApplications != null) {
          executionResults.addAll(await _applyDefinitionMacros(
              libraryBuilder.origin, classApplicationData.classApplications!));
        }
      }
      if (executionResults.isNotEmpty) {
        List<macro.Span> spans = [];
        String result = _macroExecutor.buildAugmentationLibrary(
            libraryBuilder.origin.importUri,
            executionResults,
            _macroIntrospection.resolveDeclaration,
            _macroIntrospection.resolveIdentifier,
            _macroIntrospection.types.inferOmittedType,
            spans: spans);
        assert(
            result.trim().isNotEmpty,
            "Empty definitions phase augmentation library source for "
            "$libraryBuilder}");
        if (retainDataForTesting) {
          dataForTesting?.libraryDefinitionResult[libraryBuilder] = result;
        }
        SourceLibraryBuilder augmentationLibrary =
            await libraryBuilder.origin.createAugmentationLibrary(result);
        augmentationLibraries.add(augmentationLibrary);
        _registerMacroExecutionResultSpan(
            libraryBuilder.origin, augmentationLibrary.importUri, spans);
      }
    }
    return augmentationLibraries;
  }

  void buildMergedAugmentationLibraries(Component component) {
    HooksForTesting? hooksForTesting =
        _sourceLoader.target.context.options.hooksForTesting;
    hooksForTesting?.beforeMergingMacroAugmentations(component);

    Map<Uri, ReOffset> reOffsetMaps = {};
    List<Uri> intermediateAugmentationUris = [];
    for (MapEntry<SourceLibraryBuilder, List<macro.MacroExecutionResult>> entry
        in _libraryResults.entries) {
      SourceLibraryBuilder originLibraryBuilder = entry.key;
      List<macro.Span> spans = [];
      String source = _macroExecutor.buildAugmentationLibrary(
          entry.key.importUri,
          entry.value,
          _macroIntrospection.resolveDeclaration,
          _macroIntrospection.resolveIdentifier,
          _macroIntrospection.types.inferOmittedType,
          spans: spans);
      Uri importUri = originLibraryBuilder.importUri;
      Uri augmentationImportUri = toMacroLibraryUri(importUri);
      Uri augmentationFileUri = toMacroLibraryUri(originLibraryBuilder.fileUri);

      Map<macro.Key, OffsetRange> output = {};
      for (macro.Span span in spans) {
        OffsetRange range =
            new OffsetRange(span.offset, span.offset + span.text.length);
        macro.Key? key = span.key;
        while (key != null) {
          output[key] = output[key].include(range);
          key = key.parent;
        }
      }
      Map<Uri, List<macro.Span>>? resultSpans =
          _libraryResultSpans[originLibraryBuilder];
      if (resultSpans != null) {
        for (MapEntry<Uri, List<macro.Span>> entry in resultSpans.entries) {
          Uri intermediateAugmentationUri = entry.key;
          intermediateAugmentationUris.add(intermediateAugmentationUri);
          Map<int, int?> reOffsetMap = {};
          List<macro.Span> spans = entry.value;
          for (macro.Span span in spans) {
            int? offset = output[span.key]?.start;
            reOffsetMap[span.offset] = offset;
          }
          if (spans.isNotEmpty) {
            reOffsetMaps[intermediateAugmentationUri] = new ReOffset(
                intermediateAugmentationUri, augmentationFileUri, reOffsetMap);
          }
        }
      }

      if (_sourceLoader
          .target.context.options.showGeneratedMacroSourcesForTesting) {
        print('==============================================================');
        print('Origin library: ${importUri}');
        print('Merged macro augmentation library: ${augmentationImportUri}');
        print('---------------------------source-----------------------------');
        print(source);
        print('==============================================================');
      }

      component.accept(new ReOffsetVisitor(reOffsetMaps));

      ScannerResult scannerResult = scanString(source,
          configuration: new ScannerConfiguration(
              enableExtensionMethods: true,
              enableNonNullable: true,
              enableTripleShift: true,
              forAugmentationLibrary: true));
      component.uriToSource[augmentationFileUri] = new Source(
          scannerResult.lineStarts,
          source.codeUnits,
          augmentationImportUri,
          augmentationFileUri);
      for (Uri intermediateAugmentationUri in intermediateAugmentationUris) {
        component.uriToSource.remove(intermediateAugmentationUri);
      }
    }

    hooksForTesting?.afterMergingMacroAugmentations(component);
  }

  void close() {
    _macroExecutor.close();
    _macroIntrospection.clear();
    if (!retainDataForTesting) {
      _libraryData.clear();
      _libraryResults.clear();
      _libraryResultSpans.clear();
    }
  }
}

macro.DeclarationKind _declarationKind(macro.Declaration declaration) {
  if (declaration is macro.ConstructorDeclaration) {
    return macro.DeclarationKind.constructor;
  } else if (declaration is macro.MethodDeclaration) {
    return macro.DeclarationKind.method;
  } else if (declaration is macro.FunctionDeclaration) {
    return macro.DeclarationKind.function;
  } else if (declaration is macro.FieldDeclaration) {
    return macro.DeclarationKind.field;
  } else if (declaration is macro.VariableDeclaration) {
    return macro.DeclarationKind.variable;
  } else if (declaration is macro.ClassDeclaration) {
    return macro.DeclarationKind.classType;
  } else if (declaration is macro.EnumDeclaration) {
    return macro.DeclarationKind.enumType;
  } else if (declaration is macro.MixinDeclaration) {
    return macro.DeclarationKind.mixinType;
  }
  throw new UnsupportedError(
      "Unexpected declaration ${declaration} (${declaration.runtimeType})");
}

/// Data needed to apply a list of macro applications to a macro target.
abstract class ApplicationData {
  final MacroIntrospection _macroIntrospection;
  final SourceLibraryBuilder libraryBuilder;
  final List<MacroApplication> macroApplications;

  ApplicationData(
      this._macroIntrospection, this.libraryBuilder, this.macroApplications);

  macro.MacroTarget get macroTarget;

  macro.DeclarationKind get declarationKind;

  Builder get builder;

  String get textForTesting;
}

class LibraryApplicationData extends ApplicationData {
  macro.MacroTarget? _macroTarget;

  LibraryApplicationData(
      super.macroIntrospection, super.libraryBuilder, super.macroApplications);

  @override
  macro.DeclarationKind get declarationKind => macro.DeclarationKind.library;

  @override
  macro.MacroTarget get macroTarget {
    return _macroTarget ??= _macroIntrospection.getLibrary(libraryBuilder);
  }

  @override
  Builder get builder => libraryBuilder;

  @override
  String get textForTesting => libraryBuilder.importUri.toString();
}

/// Data needed to apply a list of macro applications to a class or member.
abstract class DeclarationApplicationData extends ApplicationData {
  macro.Declaration? _declaration;

  DeclarationApplicationData(
      super._macroIntrospection, super.libraryBuilder, super.macroApplications);

  @override
  macro.MacroTarget get macroTarget => declaration;

  macro.Declaration get declaration;

  @override
  macro.DeclarationKind get declarationKind => _declarationKind(declaration);
}

class ClassApplicationData extends DeclarationApplicationData {
  final SourceClassBuilder _classBuilder;

  ClassApplicationData(super.macroIntrospection, super.libraryBuilder,
      this._classBuilder, super.macroApplications);

  @override
  macro.Declaration get declaration {
    return _declaration ??=
        _macroIntrospection.getClassDeclaration(_classBuilder);
  }

  @override
  Builder get builder => _classBuilder;

  @override
  String get textForTesting => _classBuilder.name;
}

class MemberApplicationData extends DeclarationApplicationData {
  final MemberBuilder _memberBuilder;

  MemberApplicationData(super.macroIntrospection, super.libraryBuilder,
      this._memberBuilder, super.macroApplications);

  @override
  macro.Declaration get declaration {
    return _declaration ??=
        _macroIntrospection.getMemberDeclaration(_memberBuilder);
  }

  @override
  Builder get builder => _memberBuilder;

  @override
  String get textForTesting {
    StringBuffer sb = new StringBuffer();
    if (_memberBuilder.classBuilder != null) {
      sb.write(_memberBuilder.classBuilder!.name);
      sb.write('.');
    }
    sb.write(_memberBuilder.name);
    return sb.toString();
  }
}

extension on macro.MacroExecutionResult {
  bool get isNotEmpty =>
      enumValueAugmentations.isNotEmpty ||
      libraryAugmentations.isNotEmpty ||
      typeAugmentations.isNotEmpty;

  void reportDiagnostics(MacroIntrospection introspection,
      MacroApplication macroApplication, ApplicationData applicationData) {
    // TODO(johnniwinther): Should the error be reported on the original
    //  annotation in case of nested macros?
    UriOffset uriOffset = macroApplication.uriOffset;
    for (macro.Diagnostic diagnostic in diagnostics) {
      // TODO(johnniwinther): Improve diagnostic reporting.
      switch (diagnostic.message.target) {
        case null:
          break;
        case macro.DeclarationDiagnosticTarget(:macro.Declaration declaration):
          uriOffset = introspection.getLocationFromDeclaration(declaration);
        case macro.TypeAnnotationDiagnosticTarget(
            :macro.TypeAnnotation typeAnnotation
          ):
          uriOffset = introspection.types
                  .getLocationFromTypeAnnotation(typeAnnotation) ??
              uriOffset;
        case macro.MetadataAnnotationDiagnosticTarget():
        // TODO(johnniwinther): Support metadata annotations.
      }
      applicationData.libraryBuilder.addProblem(
          templateUnspecified.withArguments(diagnostic.message.message),
          uriOffset.fileOffset,
          -1,
          uriOffset.uri);
    }
    if (exception != null) {
      // TODO(johnniwinther): Improve exception reporting.
      applicationData.libraryBuilder.addProblem(
          templateUnspecified.withArguments('${exception.runtimeType}: '
              '${exception!.message}\n${exception!.stackTrace}'),
          uriOffset.fileOffset,
          -1,
          uriOffset.uri);
    }
  }
}

extension DeclarationKindHelper on macro.DeclarationKind {
  /// Returns the plural form description for the declaration kind.
  String plural() => switch (this) {
        macro.DeclarationKind.classType => 'classes',
        macro.DeclarationKind.constructor => 'constructors',
        macro.DeclarationKind.enumType => 'enums',
        macro.DeclarationKind.enumValue => 'enum values',
        macro.DeclarationKind.extension => 'extensions',
        macro.DeclarationKind.extensionType => 'extension types',
        macro.DeclarationKind.field => 'fields',
        macro.DeclarationKind.function => 'functions',
        macro.DeclarationKind.library => 'libraries',
        macro.DeclarationKind.method => 'methods',
        macro.DeclarationKind.mixinType => 'mixin declarations',
        macro.DeclarationKind.typeAlias => 'typedefs',
        macro.DeclarationKind.variable => 'variables',
      };

  /// Returns the list of [kinds] in text as "a, b or c" to use in messaging.
  static String joinWithOr(Iterable<macro.DeclarationKind> kinds) {
    List<String> pluralTexts = kinds.map((e) => e.plural()).toList();
    if (pluralTexts.length == 1) {
      return pluralTexts.single;
    }
    return '${pluralTexts.take(pluralTexts.length - 1).join(', ')}'
        ' or ${pluralTexts.last}';
  }
}
