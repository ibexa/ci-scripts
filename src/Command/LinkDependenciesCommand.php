<?php

/**
 * @copyright Copyright (C) Ibexa AS. All rights reserved.
 * @license For full copyright and license information view LICENSE file distributed with this source code.
 */
declare(strict_types=1);

namespace Ibexa\ContiniousIntegrationScripts\Command;

use Github\AuthMethod;
use Github\Client;
use Ibexa\ContiniousIntegrationScripts\Helper\ComposerLocalTokenProvider;
use Ibexa\ContiniousIntegrationScripts\ValueObject\ComposerPullRequestData;
use Ibexa\ContiniousIntegrationScripts\ValueObject\Dependencies;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\Style\SymfonyStyle;
use Symfony\Component\Filesystem\Path;
use Symfony\Component\Serializer\Encoder\JsonEncoder;
use Symfony\Component\Serializer\Normalizer\ObjectNormalizer;
use Symfony\Component\Serializer\Serializer;

class LinkDependenciesCommand extends Command
{
    public const DEPENDENCIES_FILE = 'dependencies.json';

    /** @var ?string */
    private $token;

    /** @var \Symfony\Component\Serializer\Serializer */
    private $serializer;

    /** @var string[] */
    private $pullRequestUrls;

    /** @var \Github\Client */
    private $githubClient;

    /** @var string */
    private $outputDirectory;

    /**
     * @var \Ibexa\ContiniousIntegrationScripts\Helper\ComposerLocalTokenProvider
     */
    private $tokenProvider;

    public function __construct($outputDirectory = null, ComposerLocalTokenProvider $tokenProvider = null)
    {
        parent::__construct();
        $this->serializer = new Serializer([new ObjectNormalizer()], [new JsonEncoder()]);
        $this->githubClient = new Client();
        $this->outputDirectory = $outputDirectory ?? '.';
        $this->tokenProvider = $tokenProvider ?? new ComposerLocalTokenProvider();
    }

    public function execute(InputInterface $input, OutputInterface $output): int
    {
        $io = new SymfonyStyle($input, $output);

        $this->token = $input->getArgument('token');

        $dependencies = $this->analyzeDependencies($this->pullRequestUrls);
        $this->createDependenciesFile($dependencies, $io);

        return Command::SUCCESS;
    }

    protected function configure(): void
    {
        $this
            ->setName('dependencies:link')
            ->setDescription(sprintf('Outputs a %s file that contains data about related Pull Requests', self::DEPENDENCIES_FILE))
            ->addArgument('token', InputArgument::OPTIONAL, 'GitHub OAuth token')
        ;
    }

    private function getPullRequestData(string $owner, string $repository, int $prNumber): ComposerPullRequestData
    {
        if ($this->token) {
            $this->githubClient->authenticate($this->token, null, AuthMethod::ACCESS_TOKEN);
        }

        $pullRequestDetails = $this->githubClient->pullRequests()->show($owner, $repository, $prNumber);

        $pullRequestData = new ComposerPullRequestData();
        $pullRequestData->repositoryUrl = $pullRequestDetails['head']['repo']['html_url'];
        $pullRequestData->shouldBeAddedAsVCS = $pullRequestDetails['head']['repo']['private'] || $pullRequestDetails['head']['repo']['fork'];
        $branchName = $pullRequestDetails['head']['ref'];
        $targetOwner = $pullRequestDetails['base']['repo']['owner']['login'];
        $targetRepository = $pullRequestDetails['base']['repo']['name'];
        $targetBranch = $pullRequestDetails['base']['ref'];

        $composerData = json_decode(
            $this->githubClient->repos()->contents()->download($targetOwner, $targetRepository, 'composer.json', $targetBranch),
            true,
            512,
            JSON_THROW_ON_ERROR
        );

        $aliases = array_keys($composerData['extra']['branch-alias']);
        $branchAlias = $composerData['extra']['branch-alias'][$aliases[0]];

        $pullRequestData->package = $composerData['name'];
        $pullRequestData->requirement = sprintf('dev-%s as %s', $branchName, $branchAlias);

        return $pullRequestData;
    }

    protected function interact(InputInterface $input, OutputInterface $output): void
    {
        $io = new SymfonyStyle($input, $output);

        if (!$input->getArgument('token')) {
            $input->setArgument('token', $this->tokenProvider->getGitHubToken());
        }

        $relatedPRsNumber = $io->ask('Please enter the number of related Pull Requests', '1', static function ($number) {
            if (!is_numeric($number) || $number < 1) {
                throw new \RuntimeException('Positive integer expected.');
            }

            return (int) $number;
        });

        $pullRequestUrls = [];
        for ($i = 0; $i < $relatedPRsNumber; ++$i) {
            $pullRequestUrls[] = $io->ask('Link to GitHub PR', null, static function ($answer) {
                if (!is_string($answer) || !str_contains($answer, 'github.com')) {
                    throw new \RuntimeException(
                        'Link to Pull Request on GitHub expected. Example: https://github.com/ibexa/recipes/pull/22'
                    );
                }

                return $answer;
            });
        }

        $this->pullRequestUrls = array_unique($pullRequestUrls);
    }

    private function createDependenciesFile(Dependencies $dependencies, SymfonyStyle $io): void
    {
        $jsonContent = $this->serializer->serialize($dependencies, 'json', ['json_encode_options' => JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT]);
        file_put_contents(Path::join($this->outputDirectory, self::DEPENDENCIES_FILE), $jsonContent);
        $io->success(sprintf('Successfully generated %s file', self::DEPENDENCIES_FILE));
    }

    /**
     * @param string[] $pullRequestUrls
     */
    private function analyzeDependencies(array $pullRequestUrls): Dependencies
    {
        $pullRequestsData = [];
        $recipesEndpoint = '';

        foreach ($pullRequestUrls as $pullRequestUrl) {
            $matches = [];
            preg_match('/.*github.com\/(.*)\/(.*)\/pull\/(\d+).*/', $pullRequestUrl, $matches);
            [, $owner, $repository, $prNumber] = $matches;
            $prNumber = (int)$prNumber;

            if ($owner === 'ibexa' && $repository === 'recipes-dev') {
                $recipesEndpoint = $this->getRecipesEndpointUrl($owner, $repository, $prNumber);
            } else {
                $pullRequestsData[] = $this->getPullRequestData($owner, $repository, $prNumber);
            }
        }

        return new Dependencies($recipesEndpoint, $pullRequestsData);
    }

    private function getRecipesEndpointUrl(string $owner, string $repository, int $prNumber): string
    {
        return sprintf(
                'https://api.github.com/repos/%s/%s/contents/index.json?ref=flex/pull-%d',
                $owner,
                $repository,
                $prNumber);
    }
}
