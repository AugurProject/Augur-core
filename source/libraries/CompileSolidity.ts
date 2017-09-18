#!/usr/bin/env node

import * as fs from 'fs';
import * as mkdirp from 'mkdirp';
import * as path from 'path';
import * as recursiveReadDir from 'recursive-readdir';
import { CompilerInput, CompilerInputSourceCode, CompilerInputSourceFile, compileStandardWrapper } from 'solc';

interface CompileContractsOutput {
    output?: string;
}

class SolidityContractCompiler {
    private contractInputDirectoryPath: string;
    private contractOutputDirectoryPath: string;
    private contractOutputFileName: string;

    public constructor(contractInputDirectoryPath: string, contractOutputDirectoryPath: string, contractOutputFileName: string) {
        this.contractInputDirectoryPath = contractInputDirectoryPath;
        this.contractOutputDirectoryPath = contractOutputDirectoryPath;
        this.contractOutputFileName = contractOutputFileName;
    }

    public async compileContracts(): Promise<CompileContractsOutput> {
        try {
            // Compile all contracts in the specified input directory
            const inputJson: CompilerInput = await this.generateCompilerInput();
            const compilerOutput: any = compileStandardWrapper(JSON.stringify(inputJson), this.readCallback);
            const compileOutputJson = JSON.parse(compilerOutput);
            if (compileOutputJson.errors) {
                let errors = "";
                for (let error of compileOutputJson.errors) {
                    errors += error.formattedMessage + "\n";
                }
                throw new Error("The following errors/warnings were returned by solc:\n\n" + errors);
            }

            // Create output directory (if it doesn't exist)
            mkdirp(this.contractOutputDirectoryPath, this.mkdirpCallback);

            // Output contract data to single file
            const contractOutputFilePath = this.contractOutputDirectoryPath + "/" + this.contractOutputFileName;
            let wstream: any = fs.createWriteStream(contractOutputFilePath);
            for (let contract in compileOutputJson.contracts) {
                wstream.write(JSON.stringify(compileOutputJson.contracts[contract]));
            }

            return { output: "Contracts in " + this.contractInputDirectoryPath + " were successfully compiled by solc and saved to " + contractOutputFilePath};
        } catch (error) {
            throw error;
        }
    }

    private ignoreFile(file: string, stats: fs.Stats): boolean {
        return stats.isFile() && path.extname(file) != ".sol";
    }

    public readCallback(path: string): { contents?: string, error?: string } {
        try {
            const result = fs.readFileSync(path, 'utf8');
            return { contents: result };
        } catch (error) {
            return { error: error.message };
        }
    }

    private mkdirpCallback(error): void {
        if (error) {
            throw new Error (error);
        }
    }

    private async generateCompilerInput(): Promise<CompilerInput> {
        let inputJson: CompilerInput = {
            "language": "Solidity",
            "sources": {}
        };
        try {
            let contractInputDirectoryPath = this.contractInputDirectoryPath;
            if (contractInputDirectoryPath.lastIndexOf(path.sep) != contractInputDirectoryPath.length) {
                contractInputDirectoryPath += path.sep;
            }

            const files: any = await recursiveReadDir(this.contractInputDirectoryPath, [this.ignoreFile]);
            for (let index in files) {
                inputJson.sources[files[index].replace(contractInputDirectoryPath, "")] = {"urls": [files[index]]};
            }
        } catch (error) {
            throw error;
        }
        return inputJson;
    }
}
